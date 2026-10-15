package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:reflect"
import "vendor:glfw"
import vk "vendor:vulkan"

// ------------------------------------------------------------------- CONSTANTS

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

// ---------------------------------------------------------------------- UTILS

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

// ---------------------------------------------------------------- VULKAN UTILS

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

get_queue_families :: proc(
	physical_device: vk.PhysicalDevice,
	queue_flags: vk.QueueFlags,
) -> (
	u32,
	bool,
) {
	count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &count, nil)

	families := make([]vk.QueueFamilyProperties, count)
	defer delete(families)

	vk.GetPhysicalDeviceQueueFamilyProperties(physical_device, &count, raw_data(families))
	for family, i in families {
		if (queue_flags & family.queueFlags) == queue_flags {
			return u32(i), true
		}
	}

	return 0, false
}

Physcial_Device_Features :: struct {
	default:                vk.PhysicalDeviceFeatures,
	vulkan11:               vk.PhysicalDeviceVulkan11Features,
	vulkan13:               vk.PhysicalDeviceVulkan13Features,
	extended_dynamic_state: vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT,
}

get_physical_device_features :: proc(
	physical_device: vk.PhysicalDevice,
) -> Physcial_Device_Features {
	vulkan13 := vk.PhysicalDeviceVulkan13Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
	}

	extended_dynamic_state := vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT {
		sType = .PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT,
	}

	vulkan13.pNext = &extended_dynamic_state

	vulkan11 := vk.PhysicalDeviceVulkan11Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		pNext = &vulkan13,
	}

	features2 := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &vulkan11,
	}

	vk.GetPhysicalDeviceFeatures2(physical_device, &features2)
	return Physcial_Device_Features {
		default = features2.features,
		vulkan11 = vulkan11,
		vulkan13 = vulkan13,
		extended_dynamic_state = extended_dynamic_state,
	}
}

score_physical_device :: proc(physical_device: vk.PhysicalDevice) -> int {
	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(physical_device, &properties)

	name := string(cstring(&properties.deviceName[0]))

	if properties.apiVersion < vk.API_VERSION_1_4 {
		fmt.printfln(
			"  %q - apiVersion=%d.%d.%d, < 1.4 (skipped)",
			name,
			vk.API_VERSION_MAJOR(properties.apiVersion),
			vk.API_VERSION_MINOR(properties.apiVersion),
			vk.API_VERSION_PATCH(properties.apiVersion),
		)

		return -1
	}

	if _, ok := get_queue_families(physical_device, {.GRAPHICS}); !ok {
		fmt.printfln("  %q - no graphics queue (skipped)", name)
		return -1
	}

	required_extensions := []cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}

	{
		extension_count: u32
		vk.EnumerateDeviceExtensionProperties(physical_device, nil, &extension_count, nil)
		available_extensions := make([]vk.ExtensionProperties, extension_count)
		defer delete(available_extensions)
		vk.EnumerateDeviceExtensionProperties(
			physical_device,
			nil,
			&extension_count,
			raw_data(available_extensions),
		)

		for extension in required_extensions {
			found := false
			for &ext in available_extensions {
				if cstring(&ext.extensionName[0]) == extension {
					found = true
					break
				}
			}
			if !found {
				fmt.printfln("  %q - missing required extension %s (skipped)", name, extension)
				return -1
			}
		}
	}

	features := get_physical_device_features(physical_device)

	if !features.vulkan11.shaderDrawParameters {
		fmt.printfln("  %q - missing shaderDrawParameters (skipped)", name)
		return -1
	}
	if !features.vulkan13.dynamicRendering {
		fmt.printfln("  %q - missing dynamicRendering (skipped)", name)
		return -1
	}
	if !features.extended_dynamic_state.extendedDynamicState {
		fmt.printfln("  %q - missing extendedDynamicState (skipped)", name)
		return -1
	}

	score := 0

	// Discrete GPU's have a significant performance advantage.
	if properties.deviceType == .DISCRETE_GPU {
		score += 1000
	} else if properties.deviceType == .INTEGRATED_GPU {
		score += 500
	}

	// Maximum possible size of textures affects graphics quality.
	score += int(properties.limits.maxImageDimension2D)

	fmt.printfln("  %q - type=%v, score=%d", name, properties.deviceType, score)
	return score
}


// ---------------------------------------------------------------- VULKAN SETUP

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

pick_physical_device :: proc(instance: vk.Instance) -> vk.PhysicalDevice {
	device_count: u32
	vk.EnumeratePhysicalDevices(instance, &device_count, nil)
	if device_count == 0 {
		fmt.eprintln("failed to find GPUs with Vulkan support!")
		os.exit(1)
	}

	physical_devices := make([]vk.PhysicalDevice, device_count)
	defer delete(physical_devices)

	vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(physical_devices))

	best_score := -1
	best_device: vk.PhysicalDevice = nil

	for device in physical_devices {
		score := score_physical_device(device)

		if score > best_score {
			best_score = score
			best_device = device
		}
	}

	if best_device == nil {
		fmt.eprintln("failed to find a suitable GPU")
		os.exit(1)
	}

	fmt.println("selected physical device")
	return best_device
}

// ----------------------------------------------------------------- APPLICATION

main :: proc() {
	fmt.println("---- Vulkan Tutorial Odin ----")

	init_glfw()
	instance := create_instance()

	_ = pick_physical_device(instance)

	if instance != nil && vk.DestroyDebugUtilsMessengerEXT != nil {
		vk.DestroyDebugUtilsMessengerEXT(instance, VK_Debug_Messenger, nil)
	}

	if instance != nil {
		vk.DestroyInstance(instance, nil)
	}
}
