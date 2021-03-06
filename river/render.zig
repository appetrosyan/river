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

const build_options = @import("build_options");
const std = @import("std");

const c = @import("c.zig");

const Box = @import("Box.zig");
const LayerSurface = @import("LayerSurface.zig");
const Output = @import("Output.zig");
const Server = @import("Server.zig");
const View = @import("View.zig");
const ViewStack = @import("view_stack.zig").ViewStack;

const SurfaceRenderData = struct {
    output: *const Output,

    /// In output layout coordinates relative to the output
    output_x: i32,
    output_y: i32,

    when: *c.timespec,
};

pub fn renderOutput(output: *Output) void {
    const wlr_renderer = output.getRenderer();

    var now: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &now);

    // wlr_output_attach_render makes the OpenGL context current.
    if (!c.wlr_output_attach_render(output.wlr_output, null)) {
        return;
    }
    // The "effective" resolution can change if you rotate your outputs.
    var width: c_int = undefined;
    var height: c_int = undefined;
    c.wlr_output_effective_resolution(output.wlr_output, &width, &height);
    // Begin the renderer (calls glViewport and some other GL sanity checks)
    c.wlr_renderer_begin(wlr_renderer, width, height);

    const color = [_]f32{ 0.0, 0.16862745, 0.21176471, 1.0 };
    c.wlr_renderer_clear(wlr_renderer, &color);

    renderLayer(output.*, output.layers[c.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND], &now);
    renderLayer(output.*, output.layers[c.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM], &now);

    // The first view in the list is "on top" so iterate in reverse.
    var it = ViewStack(View).reverseIterator(output.views.last, output.current_focused_tags);
    while (it.next()) |node| {
        const view = &node.view;
        // This check prevents a race condition when a frame is requested
        // between mapping of a view and the first configure being handled.
        if (view.current_box.width == 0 or view.current_box.height == 0) {
            continue;
        }
        // Floating views are rendered on top of normal views
        if (view.floating) {
            continue;
        }
        renderView(output.*, view, &now);
        renderBorders(output.*, view, &now);
    }

    // Render floating views
    it = ViewStack(View).reverseIterator(output.views.last, output.current_focused_tags);
    while (it.next()) |node| {
        const view = &node.view;
        // This check prevents a race condition when a frame is requested
        // between mapping of a view and the first configure being handled.
        if (view.current_box.width == 0 or view.current_box.height == 0) {
            continue;
        }
        if (!view.floating) {
            continue;
        }
        renderView(output.*, view, &now);
        renderBorders(output.*, view, &now);
    }

    // Render xwayland unmanged views
    if (build_options.xwayland) {
        renderXwaylandUnmanaged(output.*, &now);
    }

    renderLayer(output.*, output.layers[c.ZWLR_LAYER_SHELL_V1_LAYER_TOP], &now);
    renderLayer(output.*, output.layers[c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY], &now);

    // Hardware cursors are rendered by the GPU on a separate plane, and can be
    // moved around without re-rendering what's beneath them - which is more
    // efficient. However, not all hardware supports hardware cursors. For this
    // reason, wlroots provides a software fallback, which we ask it to render
    // here. wlr_cursor handles configuring hardware vs software cursors for you,
    // and this function is a no-op when hardware cursors are in use.
    c.wlr_output_render_software_cursors(output.wlr_output, null);

    // Conclude rendering and swap the buffers, showing the final frame
    // on-screen.
    c.wlr_renderer_end(wlr_renderer);
    // TODO: handle failure
    _ = c.wlr_output_commit(output.wlr_output);
}

/// Render all surfaces on the passed layer
fn renderLayer(output: Output, layer: std.TailQueue(LayerSurface), now: *c.timespec) void {
    var it = layer.first;
    while (it) |node| : (it = node.next) {
        const layer_surface = &node.data;
        var rdata = SurfaceRenderData{
            .output = &output,
            .output_x = layer_surface.box.x,
            .output_y = layer_surface.box.y,
            .when = now,
        };
        c.wlr_layer_surface_v1_for_each_surface(
            layer_surface.wlr_layer_surface,
            renderSurface,
            &rdata,
        );
    }
}

fn renderView(output: Output, view: *View, now: *c.timespec) void {
    // If we have a stashed buffer, we are in the middle of a transaction
    // and need to render that buffer until the transaction is complete.
    if (view.stashed_buffer) |buffer| {
        var box = c.wlr_box{
            .x = view.current_box.x,
            .y = view.current_box.y,
            .width = @intCast(c_int, view.current_box.width),
            .height = @intCast(c_int, view.current_box.height),
        };

        // Scale the box to the output's current scaling factor
        scaleBox(&box, output.wlr_output.scale);

        var matrix: [9]f32 = undefined;
        c.wlr_matrix_project_box(
            &matrix,
            &box,
            .WL_OUTPUT_TRANSFORM_NORMAL,
            0.0,
            &output.wlr_output.transform_matrix,
        );

        // This takes our matrix, the texture, and an alpha, and performs the actual
        // rendering on the GPU.
        _ = c.wlr_render_texture_with_matrix(
            output.getRenderer(),
            buffer.texture,
            &matrix,
            1.0,
        );
    } else {
        // Since there is no stashed buffer, we are not in the middle of
        // a transaction and may simply render each toplevel surface.
        var rdata = SurfaceRenderData{
            .output = &output,
            .output_x = view.current_box.x,
            .output_y = view.current_box.y,
            .when = now,
        };

        view.forEachSurface(renderSurface, &rdata);
    }
}

/// Render all xwayland unmanaged windows that appear on the output
fn renderXwaylandUnmanaged(output: Output, now: *c.timespec) void {
    const root = output.root;
    const output_box: *c.wlr_box = c.wlr_output_layout_get_box(
        root.wlr_output_layout,
        output.wlr_output,
    );

    var it = output.root.xwayland_unmanaged_views.first;
    while (it) |node| : (it = node.next) {
        const wlr_xwayland_surface = node.data.wlr_xwayland_surface;

        var rdata = SurfaceRenderData{
            .output = &output,
            .output_x = wlr_xwayland_surface.x - output_box.x,
            .output_y = wlr_xwayland_surface.y - output_box.y,
            .when = now,
        };
        c.wlr_surface_for_each_surface(wlr_xwayland_surface.surface, renderSurface, &rdata);
    }
}

/// This function is passed to wlroots to render each surface during iteration
fn renderSurface(
    _surface: ?*c.wlr_surface,
    surface_x: c_int,
    surface_y: c_int,
    data: ?*c_void,
) callconv(.C) void {
    // wlroots says this will never be null
    const surface = _surface.?;
    const rdata = @ptrCast(*SurfaceRenderData, @alignCast(@alignOf(SurfaceRenderData), data));
    const output = rdata.output;
    const wlr_output = output.wlr_output;

    // We first obtain a wlr_texture, which is a GPU resource. wlroots
    // automatically handles negotiating these with the client. The underlying
    // resource could be an opaque handle passed from the client, or the client
    // could have sent a pixel buffer which we copied to the GPU, or a few other
    // means. You don't have to worry about this, wlroots takes care of it.
    const texture = c.wlr_surface_get_texture(surface);
    if (texture == null) {
        return;
    }

    var box = c.wlr_box{
        .x = rdata.output_x + surface_x,
        .y = rdata.output_y + surface_y,
        .width = surface.current.width,
        .height = surface.current.height,
    };

    // Scale the box to the output's current scaling factor
    scaleBox(&box, wlr_output.scale);

    // wlr_matrix_project_box is a helper which takes a box with a desired
    // x, y coordinates, width and height, and an output geometry, then
    // prepares an orthographic projection and multiplies the necessary
    // transforms to produce a model-view-projection matrix.
    var matrix: [9]f32 = undefined;
    const transform = c.wlr_output_transform_invert(surface.current.transform);
    c.wlr_matrix_project_box(&matrix, &box, transform, 0.0, &wlr_output.transform_matrix);

    // This takes our matrix, the texture, and an alpha, and performs the actual
    // rendering on the GPU.
    _ = c.wlr_render_texture_with_matrix(output.getRenderer(), texture, &matrix, 1.0);

    // This lets the client know that we've displayed that frame and it can
    // prepare another one now if it likes.
    c.wlr_surface_send_frame_done(surface, rdata.when);
}

fn renderBorders(output: Output, view: *View, now: *c.timespec) void {
    var border: Box = undefined;
    const color = if (view.focused)
        [_]f32{ 0.57647059, 0.63137255, 0.63137255, 1.0 } // Solarized base1
    else
        [_]f32{ 0.34509804, 0.43137255, 0.45882353, 1.0 }; // Solarized base01
    const border_width = output.root.server.config.border_width;

    // left and right, covering the corners as well
    border.y = view.current_box.y - @intCast(i32, border_width);
    border.width = border_width;
    border.height = view.current_box.height + border_width * 2;

    // left
    border.x = view.current_box.x - @intCast(i32, border_width);
    renderRect(output, border, color);

    // right
    border.x = view.current_box.x + @intCast(i32, view.current_box.width);
    renderRect(output, border, color);

    // top and bottom
    border.x = view.current_box.x;
    border.width = view.current_box.width;
    border.height = border_width;

    // top
    border.y = view.current_box.y - @intCast(i32, border_width);
    renderRect(output, border, color);

    // bottom border
    border.y = view.current_box.y + @intCast(i32, view.current_box.height);
    renderRect(output, border, color);
}

fn renderRect(output: Output, box: Box, color: [4]f32) void {
    var wlr_box = box.toWlrBox();
    scaleBox(&wlr_box, output.wlr_output.scale);
    c.wlr_render_rect(
        output.getRenderer(),
        &wlr_box,
        &color,
        &output.wlr_output.transform_matrix,
    );
}

/// Scale a wlr_box, taking the possibility of fractional scaling into account.
fn scaleBox(box: *c.wlr_box, scale: f64) void {
    box.x = @floatToInt(c_int, @round(@intToFloat(f64, box.x) * scale));
    box.y = @floatToInt(c_int, @round(@intToFloat(f64, box.y) * scale));
    box.width = scaleLength(box.width, box.x, scale);
    box.height = scaleLength(box.height, box.x, scale);
}

/// Scales a width/height.
///
/// This might seem overly complex, but it needs to work for fractional scaling.
fn scaleLength(length: c_int, offset: c_int, scale: f64) c_int {
    return @floatToInt(c_int, @round(@intToFloat(f64, offset + length) * scale) -
        @round(@intToFloat(f64, offset) * scale));
}
