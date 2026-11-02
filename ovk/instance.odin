package ovk

import vk "vendor:vulkan"

Instance :: struct {
	instance:        vk.Instance,
	debug_messenger: vk.DebugUtilsMessengerEXT,
}
