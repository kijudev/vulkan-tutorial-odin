package ovk

import vk "vendor:vulkan"

Ovk_Error :: struct {
	message: string,
}

Vulkan_Error :: struct {
	result:  vk.Result,
	message: string,
}

GLFW_Error :: struct {
	message: string,
}

Error :: union {
	Ovk_Error,
	Vulkan_Error,
	GLFW_Error,
}
