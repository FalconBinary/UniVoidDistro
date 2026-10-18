// Copyright (c) 2026 Denys (FalconBinary)
// SPDX-License-Identifier: GPL-3.0-or-later

// RefursWM never runs nested inside another compositor, so wlroots' Wayland backend (and with it
// libwayland-client) is not built. backend/backend.c only calls these when WAYLAND_DISPLAY is set
// and WLR_BACKENDS is not; RefursWM then fails to start, as it should.
#include <stddef.h>

struct wl_event_loop;
struct wl_display;
struct wlr_backend;
struct wlr_output;

struct wlr_backend *wlr_wl_backend_create(struct wl_event_loop *loop, struct wl_display *remote_display);
struct wlr_output *wlr_wl_output_create(struct wlr_backend *backend);

struct wlr_backend *wlr_wl_backend_create(struct wl_event_loop *loop, struct wl_display *remote_display) {
	(void)loop;
	(void)remote_display;
	return NULL;
}

struct wlr_output *wlr_wl_output_create(struct wlr_backend *backend) {
	(void)backend;
	return NULL;
}
