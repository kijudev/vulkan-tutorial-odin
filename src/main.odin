package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:reflect"
import "vendor:glfw"
import vk "vendor:vulkan"

VK_Debug_Messenger: vk.DebugUtilsMessengerEXT = {}
VK_Debug_Level: vk.DebugUtilsMessageSeverityFlagsEXT = {.WARNING, .ERROR}
VK_Validation_Layers := []cstring{"VK_LAYER_KHRONOS_validation"}

check_vk_result :: proc(result: vk.Result, op: string, loc := #caller_location) {
	if result == .SUCCESS do return
	fail := context.assertion_failure_proc

	when ODIN_DEBUG {
		fail(op, reflect.enum_string(result), loc)
	} else {
		fail(op, "VK: operation failed", loc)
	}
}

check_b32 :: proc(result: b32, op: string, loc := #caller_location) {
	if result do return
	context.assertion_failure_proc(op, "false", loc)
}

check :: proc {
	check_vk_result,
	check_b32,
}

init_glfw :: proc() {
	if !glfw.Init() {
		fmt.eprintln("GLFW: failed to initialize")
		os.exit(1)
	} else {
		fmt.println("GLFW: initialized")
	}
}

check_layer_support :: proc(required_layers: []cstring) -> b32 {
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

debug_callback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageTypes: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,
) -> b32 {
	context = runtime.default_context()

	if pCallbackData.pMessageIdName == "Loader Message" && .ERROR not_in messageSeverity do return false

	if .ERROR in messageSeverity && .ERROR in VK_Debug_Level {
		fmt.eprintfln("[validation ERROR] %s", pCallbackData.pMessage)
	} else if .WARNING in messageSeverity && .WARNING in VK_Debug_Level {
		fmt.eprintfln("[validation WARNING] %s", pCallbackData.pMessage)
	} else if .INFO in messageSeverity && .INFO in VK_Debug_Level {
		fmt.println("[validation INFO]", pCallbackData.pMessage)
	} else if .VERBOSE in messageSeverity && .VERBOSE in VK_Debug_Level {
		fmt.printfln("[validation VERBOSE] %s", pCallbackData.pMessage)
	}

	return false
}


create_instance :: proc() -> vk.Instance {
	vk.load_proc_addresses(rawptr(glfw.GetInstanceProcAddress))
	check(check_layer_support(VK_Validation_Layers), "validation layers not available")

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
		messageSeverity = VK_Debug_Level,
		messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = debug_callback,
		pUserData       = nil,
	}

	instance_ci := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &application_i,
		enabledExtensionCount   = u32(len(extension_names)),
		ppEnabledExtensionNames = raw_data(extension_names[:]),
		enabledLayerCount       = u32(len(VK_Validation_Layers)),
		ppEnabledLayerNames     = raw_data(VK_Validation_Layers),
		pNext                   = &debug_ci,
	}

	instance: vk.Instance
	check(vk.CreateInstance(&instance_ci, nil, &instance), "failed to create instance")
	fmt.println("VK: instance created")

	vk.load_proc_addresses_instance(instance)

	if vk.CreateDebugUtilsMessengerEXT != nil {
		check(
			vk.CreateDebugUtilsMessengerEXT(instance, &debug_ci, nil, &VK_Debug_Messenger),
			"failed to create debug messenger",
		)
	}

	return instance
}

main :: proc() {
	fmt.println("---- Vulkan Tutorial Odin ----")

	init_glfw()
	instance := create_instance()

	if instance != nil && vk.DestroyDebugUtilsMessengerEXT != nil {
		vk.DestroyDebugUtilsMessengerEXT(instance, VK_Debug_Messenger, nil)
	}

	if instance != nil {
		vk.DestroyInstance(instance, nil)
	}
}
