package ovk

import vk "vendor:vulkan"

// >-------------------------------------------------------- Constants and Types

Instance :: struct {
	handle:                vk.Instance,
	debug_messenger:       vk.DebugUtilsMessengerEXT,
	api_version:           u32,
	is_validation_enabled: bool,
	extensions:            []string,
	layers:                []string,
}
