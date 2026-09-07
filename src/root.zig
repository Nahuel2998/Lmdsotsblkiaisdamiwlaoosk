const std = @import("std");
const c   = @import("xcb");
// const c   = @import("xcb_gen.zig");

const LINE_WIDTH_STEP = 4;
const LINE_WIDTH      = 12;
const LINE_COLOR      = 0xFFFFFFFF;

const Self = @This();
const Size = struct {
    width:  u16,
    height: u16,

    fn rect(self: Size) c.xcb_rectangle_t {
        return .{
            .x = 0, .y = 0,
            .width  = self.width,
            .height = self.height,
        };
    }
};
const Position = c.xcb_point_t;

conn:    *c.xcb_connection_t,
screen:  *c.xcb_screen_t,
window:   c.xcb_window_t,
graphics: c.xcb_gcontext_t,

window_size: Size,
solid:       bool = true,

drawig: ?Position = null,
erasig:      bool = false,
line_width:   u32 = LINE_WIDTH,

pub fn init(conn: *c.xcb_connection_t, pref_screen: c_int) !Self {
    const screen = try getScreen(conn, pref_screen);

    const visual   = findArgbVisual(screen) orelse return error.NoVisual;
    const colormap = c.xcb_generate_id(conn);
    xcbVoidCheck(
        conn,
        c.xcb_create_colormap_checked(
            conn,
            c.XCB_COLORMAP_ALLOC_NONE,
            colormap,
            screen.root,
            visual.visual_id,
        ),
    ) catch return error.NoColormap;

    const window_size: Size = .{
        .width  = screen.width_in_pixels,
        .height = screen.height_in_pixels,
    };
    const window = c.xcb_generate_id(conn);
    const cwmask = c.XCB_CW_BACK_PIXEL
                 | c.XCB_CW_BORDER_PIXEL
                 | c.XCB_CW_OVERRIDE_REDIRECT
                 | c.XCB_CW_EVENT_MASK
                 | c.XCB_CW_COLORMAP;
    const evmask = c.XCB_EVENT_MASK_BUTTON_PRESS 
                 | c.XCB_EVENT_MASK_BUTTON_RELEASE 
                 | c.XCB_EVENT_MASK_BUTTON_1_MOTION;
    xcbVoidCheck(
        conn,
        c.xcb_create_window_aux_checked(
            conn, 32,
            window, screen.root,
            0, 0, window_size.width, window_size.height, 0,
            c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            visual.visual_id,
            cwmask, &.{
                .background_pixel  = 0,
                .border_pixel      = 0,
                .override_redirect = 1,
                .event_mask        = evmask,
                .colormap          = colormap,
            },
        ),
    ) catch return error.NoWindow;

    const graphics = c.xcb_generate_id(conn);
    const gcmask   = c.XCB_GC_LINE_WIDTH
                   | c.XCB_GC_CAP_STYLE
                   | c.XCB_GC_JOIN_STYLE;
    xcbVoidCheck(
        conn,
        c.xcb_create_gc_aux_checked(
            conn,
            graphics, window,
            gcmask, &.{
                .line_width = LINE_WIDTH,
                .cap_style  = c.XCB_CAP_STYLE_ROUND,
                .join_style = c.XCB_JOIN_STYLE_ROUND,
            },
        ),
    ) catch return error.NoGraphics;

    var self: Self = .{
        .conn        = conn,
        .screen      = screen,
        .window      = window,
        .graphics    = graphics,
        .window_size = window_size,
    };
    self.setSolid(false);
    _ = c.xcb_map_window(conn, window);
    self.raise();
    self.setLineColor(LINE_COLOR);
    _ = c.xcb_flush(conn);

    return self;
}

pub fn deinit(self: *Self) void {
    _ = c.xcb_free_gc(self.conn, self.graphics);
    _ = c.xcb_flush(self.conn);
}

pub fn drainXEvents(self: *Self) void {
    while (c.xcb_poll_for_event(self.conn)) |event| {
        defer std.c.free(event);
        self.handleXEvent(event);
    }
}

pub fn handleXEvent(self: *Self, event: *c.xcb_generic_event_t) void {
    const evtype = event.response_type & 0x7f;
    
    switch (evtype) {
        c.XCB_NONE => {
            const ev: *c.xcb_generic_error_t = @ptrCast(event);
            std.log.err("XCB Error: code={} major={} minor={}", .{ev.error_code, ev.major_code, ev.minor_code});
        },
        c.XCB_MOTION_NOTIFY => {
            const ev: *c.xcb_motion_notify_event_t = @ptrCast(event);

            const points: [2]c.xcb_point_t = .{
                self.drawig.?,
                .{ .x = ev.event_x, .y = ev.event_y }
            };
            _ = c.xcb_poly_line(self.conn, c.XCB_COORD_MODE_ORIGIN, self.window, self.graphics, 2, &points);
            _ = c.xcb_flush(self.conn);

            self.drawig = points[1];
        },
        c.XCB_BUTTON_PRESS => {
            const ev: *c.xcb_button_press_event_t = @ptrCast(event);
            switch (ev.detail) {
                c.XCB_BUTTON_INDEX_1 => self.drawig = .{ .x = ev.event_x, .y = ev.event_y },
                c.XCB_BUTTON_INDEX_2 => {
                    self.clear();
                    _ = c.xcb_flush(self.conn);
                },
                c.XCB_BUTTON_INDEX_3 => {
                    self.erasig = !self.erasig;

                    const color: u32 = if (self.erasig) 0 else LINE_COLOR;
                    self.setLineColor(color);
                },
                c.XCB_BUTTON_INDEX_4 => {
                    self.tweakLineWidth(LINE_WIDTH_STEP);
                },
                c.XCB_BUTTON_INDEX_5 => {
                    self.tweakLineWidth(-LINE_WIDTH_STEP);
                },
                else => {},
            }
        },
        c.XCB_BUTTON_RELEASE => {
            const ev: *c.xcb_button_release_event_t = @ptrCast(event);
            if (ev.detail == c.XCB_BUTTON_INDEX_1) {
                self.drawig = null;
            }
        },
        else => {}
    }
}

pub inline fn toggleSolid(self: *Self) void {
    self.setSolid(!self.solid);
}

fn setSolid(self: *Self, solid: bool) void {
    if (self.solid == solid) return;

    self.solid = solid;
    const rect = if (solid) &self.window_size.rect() else null;
    _ = c.xcb_shape_rectangles(
        self.conn, c.XCB_SHAPE_SO_SET,
        c.XCB_SHAPE_SK_INPUT, c.XCB_CLIP_ORDERING_UNSORTED,
        self.window,
        0, 0,
        @intFromBool(rect != null), rect,
    );

    if (solid) {
        if (self.erasig) {
            self.setLineColor(LINE_COLOR);
            self.erasig = false;
        }
        self.raise();
    }
}

fn setLineColor(self: *Self, color: u32) void {
    _ = c.xcb_change_gc_aux(
        self.conn,
        self.graphics,
        c.XCB_GC_FOREGROUND,
        &.{ .foreground = color },
    );
}

fn tweakLineWidth(self: *Self, delta: i32) void {
    const abs = @abs(delta);
    if (delta > 0) { self.line_width +|= abs; }
    else           { self.line_width -|= abs; }
    _ = c.xcb_change_gc_aux(
        self.conn,
        self.graphics,
        c.XCB_GC_LINE_WIDTH,
        &.{ .line_width = self.line_width },
    );
    std.log.info("Line width: {}", .{ self.line_width });
}

fn fulfill(self: *Self) void {
    const rect = self.window_size.rect();
    _ = c.xcb_poly_fill_rectangle(self.conn, self.window, self.graphics, 1, &rect);
}

fn clear(self: *Self) void {
    if (!self.erasig) {
        self.setLineColor(0);
    }
    self.fulfill();
    self.setLineColor(LINE_COLOR);
    self.erasig = false;
}

fn raise(self: *Self) void {
    _ = c.xcb_configure_window_aux(
        self.conn, self.window,
        c.XCB_CONFIG_WINDOW_STACK_MODE, &.{ .stack_mode = c.XCB_STACK_MODE_ABOVE },
    );
}

fn getScreen(conn: *c.xcb_connection_t, num: c_int) !*c.xcb_screen_t {
    const setup = c.xcb_get_setup(conn);
    var   iter  = c.xcb_setup_roots_iterator(setup);
    for (0..@intCast(num)) |_| {
        if (iter.rem == 0) return error.NoScreen;
        c.xcb_screen_next(&iter);
    }
    return iter.data;
}

fn findArgbVisual(screen: *c.xcb_screen_t) ?*c.xcb_visualtype_t {
    var iter = c.xcb_screen_allowed_depths_iterator(screen);
    while (iter.rem > 0) : (c.xcb_depth_next(&iter)) {
        if (iter.data.*.depth != 32) continue;

        const visual_iter = c.xcb_depth_visuals_iterator(iter.data);
        if (visual_iter.rem == 0) continue;

        return visual_iter.data;
    }
    return null;
}

fn xcbVoidCheck(conn: *c.xcb_connection_t, cookie: c.xcb_void_cookie_t) !void {
    const err = c.xcb_request_check(conn, cookie);
    if (err != null) {
        std.c.free(err);
        return error.CheckFailed;
    }
}
