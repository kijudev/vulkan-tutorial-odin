package main

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "vendor:glfw"
import vk "vendor:vulkan"

vk_debug_messenger: vk.DebugUtilsMessengerEXT = {}
vk_debug_level: vk.DebugUtilsMessageSeverityFlagsEXT = {.WARNING, .ERROR}
vk_validation_layers := []cstring{"VK_LAYER_KHRONOS_validation"}

vk_must_result :: proc(result: vk.Result, op: string, loc := #caller_location) {
	if result == .SUCCESS do return
	fail := context.assertion_failure_proc

	when ODIN_DEBUG {
		fail(op, reflect.enum_string(result), loc)
	} else {
		fail(op, "VK: operation failed", loc)
	}
}

vk_must_b32 :: proc(result: b32, op: string, loc := #caller_location) {
	if result do return
	context.assertion_failure_proc(op, "false", loc)
}

vk_must :: proc {
	vk_must_result,
	vk_must_b32,
}

vk_check_layer_support :: proc(required_layers: []cstring) -> b32 {
	layer_count: u32
	vk.EnumerateInstanceLayerProperties(&layer_count, nil)

	available_layers := make([]vk.LayerProperties, layer_count)
	defer delete(available_layers)

	vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(available_layers))
	for req_layer in required_layers {
		found := false

		for &layer in available_layers {
			if cstring(&layer.layerName[0]) == req_layer {
				found = true
				break
			}
		}

		if !found do return false
	}

	return true
}

vk_debug_callback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,
) -> b32 {
	context = runtime.default_context()

	if pCallbackData.pMessageIdName == "Loader Message" && .ERROR not_in messageSeverity do return false

	if .ERROR in messageSeverity && .ERROR in vk_debug_level {
		fmt.eprintfln("[validation ERROR] %s", pCallbackData.pMessage)
	} else if .WARNING in messageSeverity && .WARNING in vk_debug_level {
		fmt.eprintfln("[validation WARNING] %s", pCallbackData.pMessage)
	} else if .INFO in messageSeverity && .INFO in vk_debug_level {
		fmt.println("[validation INFO]", pCallbackData.pMessage)
	} else if .VERBOSE in messageSeverity && .VERBOSE in vk_debug_level {
		fmt.printfln("[validation VERBOSE] %s", pCallbackData.pMessage)
	}

	return false
}

glfw_must_init :: proc() {
	if !glfw.Init() {
		fmt.eprintln("GLFW: failed to initialize")
	} else {
		fmt.println("GLFW: initialized")
	}
}

vk_must_create_instance :: proc() -> vk.Instance {
	vk.load_proc_addresses(rawptr(glfw.GetInstanceProcAddress))
	vk_must(vk_check_layer_support(vk_validation_layers), "validation layers not available")

	application_i := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = "vulkan-tutorial-odin",
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		pEngineName        = "farfocel",
		engineVersion      = vk.MAKE_VERSION(1, 0, 0),
		apiVersion         = vk.API_VERSION_1_4,
	}

	extensions := glfw.GetRequiredInstanceExtensions()
	extension_names: [dynamic]cstring
	defer delete(extension_names)

	append(&extension_names, ..extensions)
	append(&extension_names, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)

	debug_ci := vk.DebugUtilsMessengerCreateInfoEXT {
		sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = vk_debug_level,
		messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = vk_debug_callback,
		pUserData       = nil,
	}

	instance_ci := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &application_i,
		enabledExtensionCount   = u32(len(extension_names)),
		ppEnabledExtensionNames = raw_data(extension_names[:]),
		enabledLayerCount       = u32(len(vk_validation_layers)),
		ppEnabledLayerNames     = raw_data(vk_validation_layers),
		pNext                   = &debug_ci,
	}

	instance: vk.Instance
	vk_must(vk.CreateInstance(&instance_ci, nil, &instance), "failed to create instance")
	fmt.println("VK: instance created")

	vk.load_proc_addresses_instance(instance)

	if vk.CreateDebugUtilsMessengerEXT != nil {
		vk_must(
			vk.CreateDebugUtilsMessengerEXT(instance, &debug_ci, nil, &vk_debug_messenger),
			"failed to create debug messenger",
		)
	}

	return instance
}

main :: proc() {
	fmt.println("---- Vulkan Tutorial Odin ----")

	glfw_must_init()
	instance := vk_must_create_instance()

	if instance != nil && vk.DestroyDebugUtilsMessengerEXT != nil {
		vk.DestroyDebugUtilsMessengerEXT(instance, vk_debug_messenger, nil)
	}

	if instance != nil {
		vk.DestroyInstance(instance, nil)
	}
}
