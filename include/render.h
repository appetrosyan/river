#ifndef ZAG_RENDER_H
#define ZAG_RENDER_H

#include <wlr/backend/session.h>

struct wlr_backend_impl;

struct wlr_backend {
	const struct wlr_backend_impl *impl;

	struct {
		/** Raised when destroyed, passed the wlr_backend reference */
		struct wl_signal destroy;
		/** Raised when new inputs are added, passed the wlr_input_device */
		struct wl_signal new_input;
		/** Raised when new outputs are added, passed the wlr_output */
		struct wl_signal new_output;
	} events;
};

struct wlr_backend *zag_wlr_backend_autocreate(struct wl_display *display);
struct wlr_renderer *zag_wlr_backend_get_renderer(struct wlr_backend *backend);
bool zag_wlr_backend_start(struct wlr_backend *backend);


#endif