package ovk

import "core:strings"
import "vendor:glfw"
import vk "vendor:vulkan"

// >-------------------------------------------------------- Constants and Types

Window :: struct {
	handle:                 glfw.WindowHandle,
	title:                  string,
	width:                  u32,
	height:                 u32,
	is_framebuffer_resized: bool,
	is_resizable:           bool,
}

// >--------------------------------------------------------------------- Window

window_create :: proc(
	title: string,
	width: u32,
	height: u32,
	is_resizable := true,
) -> (
	Window,
	Error,
) {
	window := Window {
		title                  = title,
		width                  = width,
		height                 = height,
		is_framebuffer_resized = false,
		is_resizable           = is_resizable,
	}

	ctitle := strings.clone_to_cstring(title, context.temp_allocator)
	window.handle = glfw.CreateWindow(i32(width), i32(height), ctitle, nil, nil)

	if window.handle == nil do return Window{}, GLFW_Error{message = "Failed to create GLFW window"}
	return window, nil
}

window_destroy :: proc(window: Window) {
	if window.handle == nil do return
	glfw.DestroyWindow(window.handle)
}

window_should_close :: proc(window: Window) -> bool {
	if window.handle == nil do return true
	return bool(glfw.WindowShouldClose(window.handle))
}

window_framebuffer_size :: proc(window: Window) -> (u32, u32) {
	if window.handle == nil do return 0, 0

	width, height := glfw.GetFramebufferSize(window.handle)
	return u32(width), u32(height)
}

window_required_extensions :: proc() -> ([]cstring, Error) {
	extensions := glfw.GetRequiredInstanceExtensions()
	if extensions == nil do return nil, GLFW_Error{message = "Failed to get required GLFW extensions"}

	return extensions, nil
}
