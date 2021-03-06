// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 Isaac Freund
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const Self = @This();

const std = @import("std");
const build_options = @import("build_options");

const c = @import("c.zig");

const Log = @import("log.zig").Log;
const Output = @import("Output.zig");
const Server = @import("Server.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;
const XwaylandUnmanaged = @import("XwaylandUnmanaged.zig");

/// Responsible for all windowing operations
server: *Server,

wlr_output_layout: *c.wlr_output_layout,
outputs: std.TailQueue(Output),

/// This output is used internally when no real outputs are available.
/// It is not advertised to clients.
noop_output: Output,

/// This list stores all unmanaged Xwayland windows. This needs to be in root
/// since X is like the wild west and who knows where these things will go.
xwayland_unmanaged_views: if (build_options.xwayland) std.TailQueue(XwaylandUnmanaged) else void,

/// Number of pending configures sent in the current transaction.
/// A value of 0 means there is no current transaction.
pending_configures: u32,

/// Handles timeout of transactions
transaction_timer: *c.wl_event_source,

pub fn init(self: *Self, server: *Server) !void {
    self.server = server;

    // Create an output layout, which a wlroots utility for working with an
    // arrangement of screens in a physical layout.
    self.wlr_output_layout = c.wlr_output_layout_create() orelse
        return error.CantCreateWlrOutputLayout;
    errdefer c.wlr_output_layout_destroy(self.wlr_output_layout);

    self.outputs = std.TailQueue(Output).init();

    const noop_wlr_output = c.river_wlr_noop_add_output(server.noop_backend) orelse
        return error.CantAddNoopOutput;
    try self.noop_output.init(self, noop_wlr_output);

    if (build_options.xwayland) {
        self.xwayland_unmanaged_views = std.TailQueue(XwaylandUnmanaged).init();
    }

    self.pending_configures = 0;

    self.transaction_timer = c.wl_event_loop_add_timer(
        self.server.wl_event_loop,
        handleTimeout,
        self,
    ) orelse return error.CantCreateTimer;
}

pub fn deinit(self: *Self) void {
    // Need to remove these listeners as the noop output will be destroyed with
    // the noop backend triggering the destroy event. However,
    // Output.handleDestroy is not intended to handle the noop output being
    // destroyed.
    c.wl_list_remove(&self.noop_output.listen_destroy.link);
    c.wl_list_remove(&self.noop_output.listen_frame.link);
    c.wl_list_remove(&self.noop_output.listen_mode.link);

    c.wlr_output_layout_destroy(self.wlr_output_layout);

    if (c.wl_event_source_remove(self.transaction_timer) < 0) unreachable;
}

pub fn addOutput(self: *Self, wlr_output: *c.wlr_output) void {
    // TODO: Handle failure
    const node = self.outputs.allocateNode(self.server.allocator) catch unreachable;
    node.data.init(self, wlr_output) catch unreachable;
    self.outputs.append(node);

    // if we previously had no real outputs, move focus from the noop output
    // to the new one.
    if (self.outputs.len == 1) {
        // TODO: move views from the noop output to the new one and focus(null)
        var it = self.server.input_manager.seats.first;
        while (it) |seat_node| : (it = seat_node.next) {
            seat_node.data.focusOutput(&self.outputs.first.?.data);
        }
    }
}

/// Arrange all views on all outputs and then start a transaction.
pub fn arrange(self: *Self) void {
    var it = self.outputs.first;
    while (it) |output_node| : (it = output_node.next) {
        output_node.data.arrangeViews();
    }
    self.startTransaction();
}

/// Initiate an atomic change to the layout. This change will not be
/// applied until all affected clients ack a configure and commit a buffer.
fn startTransaction(self: *Self) void {
    // If a new transaction is started while another is in progress, we need
    // to reset the pending count to 0 and clear serials from the views
    self.pending_configures = 0;

    // Iterate over all views of all outputs
    var output_it = self.outputs.first;
    while (output_it) |node| : (output_it = node.next) {
        const output = &node.data;
        var view_it = ViewStack(View).iterator(output.views.first, std.math.maxInt(u32));
        while (view_it.next()) |view_node| {
            const view = &view_node.view;

            switch (view.configureAction()) {
                .override => {
                    view.configure();

                    // Some clients do not ack a configure if the requested
                    // size is the same as their current size. Configures of
                    // this nature may be sent if a pending configure is
                    // interrupted by a configure returning to the original
                    // size.
                    if (view.pending_box.?.width == view.current_box.width and
                        view.pending_box.?.height == view.current_box.height)
                    {
                        view.pending_serial = null;
                    } else {
                        std.debug.assert(view.pending_serial != null);
                        self.pending_configures += 1;
                    }
                },
                .new_configure => {
                    view.configure();
                    self.pending_configures += 1;
                    std.debug.assert(view.pending_serial != null);
                },
                .old_configure => {
                    self.pending_configures += 1;
                    view.next_box = null;
                    std.debug.assert(view.pending_serial != null);
                },
                .noop => {
                    view.next_box = null;
                    std.debug.assert(view.pending_serial == null);
                },
            }

            // If there is a saved buffer present, then this transaction is
            // interrupting a previous transaction and we should keep the old
            // buffer.
            if (view.stashed_buffer == null) {
                view.stashBuffer();

                // We save the current buffer, so we can send an early
                // frame done event to give the client a head start on
                // redrawing.
                view.sendFrameDone();
            }
        }
    }

    // If there are views that need configures, start a timer and wait for
    // configure events before committing.
    if (self.pending_configures > 0) {
        Log.Debug.log(
            "Started transaction with {} pending configures.",
            .{self.pending_configures},
        );

        // Set timeout to 200ms
        if (c.wl_event_source_timer_update(self.transaction_timer, 200) < 0) {
            Log.Error.log("failed to update timer.", .{});
            self.commitTransaction();
        }
    } else {
        // No views need configures, clear the current timer in case we are
        // interrupting another transaction and commit.
        if (c.wl_event_source_timer_update(self.transaction_timer, 0) < 0)
            Log.Error.log("Error disarming timer", .{});
        self.commitTransaction();
    }
}

fn handleTimeout(data: ?*c_void) callconv(.C) c_int {
    const self = @ptrCast(*Self, @alignCast(@alignOf(*Self), data));

    Log.Error.log("Transaction timed out. Some imperfect frames may be shown.", .{});

    self.commitTransaction();

    return 0;
}

pub fn notifyConfigured(self: *Self) void {
    self.pending_configures -= 1;
    if (self.pending_configures == 0) {
        // Disarm the timer, as we didn't timeout
        if (c.wl_event_source_timer_update(self.transaction_timer, 0) < 0)
            Log.Error.log("Error disarming timer", .{});
        self.commitTransaction();
    }
}

/// Apply the pending state and drop stashed buffers. This means that
/// the next frame drawn will be the post-transaction state of the
/// layout. Should only be called after all clients have configured for
/// the new layout. If called early imperfect frames may be drawn.
fn commitTransaction(self: *Self) void {
    // TODO: apply damage properly

    // Ensure this is set to 0 to avoid entering invalid state (e.g. if called due to timeout)
    self.pending_configures = 0;

    // Iterate over all views of all outputs
    var output_it = self.outputs.first;
    while (output_it) |output_node| : (output_it = output_node.next) {
        const output = &output_node.data;

        // If there were pending focused tags, make them the current focus
        if (output.pending_focused_tags) |tags| {
            Log.Debug.log(
                "changing current focus: {b:0>10} to {b:0>10}",
                .{ output.current_focused_tags, tags },
            );
            output.current_focused_tags = tags;
            output.pending_focused_tags = null;
            var it = output.status_trackers.first;
            while (it) |node| : (it = node.next) node.data.sendFocusedTags();
        }

        var view_tags_changed = false;

        var view_it = ViewStack(View).iterator(output.views.first, std.math.maxInt(u32));
        while (view_it.next()) |view_node| {
            const view = &view_node.view;
            // Ensure that all pending state is cleared
            view.pending_serial = null;
            std.debug.assert(view.next_box == null);
            if (view.pending_box) |state| {
                view.current_box = state;
                view.pending_box = null;
            }

            // Apply possible pending tags
            if (view.pending_tags) |tags| {
                view.current_tags = tags;
                view.pending_tags = null;
                view_tags_changed = true;
            }

            view.dropStashedBuffer();
        }

        if (view_tags_changed) output.sendViewTags();
    }

    // Iterate over all seats and update focus
    var it = self.server.input_manager.seats.first;
    while (it) |seat_node| : (it = seat_node.next) {
        seat_node.data.focus(null);
    }
}
