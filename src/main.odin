package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "vendor:glfw"
import vk "vendor:vulkan"

// ------------------------------------------------------------------- CONSTANTS

VK_Debug_Messenger: vk.DebugUtilsMessengerEXT = {}
VK_Debug_Level: vk.DebugUtilsMessageSeverityFlagsEXT = {.WARNING, .ERROR}
VK_Validation_Layers := []cstring{"VK_LAYER_KHRONOS_validation"}
VK_Required_Extensions := []cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}

// ---------------------------------------------------------------- VULKAN UTILS


check_layer_support :: proc(required_layers: []cstring) -> bool {
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
	surface: vk.SurfaceKHR,
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
			// Surface is a non-dispatchable handle, not a pointer,
			// its 0 value is like nil value of a pointer.
			// This is needed beacuse sometimes we only want to check
			// for certain features of queue families
			// and do not look at the surface support.
			if surface == 0 || is_surface_supported(physical_device, u32(i), surface) {
				return u32(i), true
			}
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

score_physical_device :: proc(physical_device: vk.PhysicalDevice, surface: vk.SurfaceKHR) -> int {
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

	if _, ok := get_queue_families(physical_device, {.GRAPHICS}, surface); !ok {
		fmt.printfln("  %q - no graphics queue (skipped)", name)
		return -1
	}


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

		for extension in VK_Required_Extensions {
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

is_surface_supported :: proc(
	physical_device: vk.PhysicalDevice,
	queue_index: u32,
	surface: vk.SurfaceKHR,
) -> bool {
	is_supported: b32

	result := vk.GetPhysicalDeviceSurfaceSupportKHR(
		physical_device,
		queue_index,
		surface,
		&is_supported,
	)

	if result != .SUCCESS do return false
	return bool(is_supported)
}


// ---------------------------------------------------------------- VULKAN SETUP


create_instance :: proc() -> vk.Instance {
	vk.load_proc_addresses(rawptr(glfw.GetInstanceProcAddress))
	ok := check_layer_support(VK_Validation_Layers)
	assert(ok, "validation layers not available")

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
	create_instance_result := vk.CreateInstance(&instance_ci, nil, &instance)
	assert(create_instance_result == .SUCCESS, "failed to create instance")

	fmt.println("VK: instance created")

	vk.load_proc_addresses_instance(instance)

	if vk.CreateDebugUtilsMessengerEXT != nil {
		ok := vk.CreateDebugUtilsMessengerEXT(instance, &debug_ci, nil, &VK_Debug_Messenger)
		assert(ok == .SUCCESS, "failed to create debug messenger")
	}

	return instance
}

pick_physical_device :: proc(instance: vk.Instance, surface: vk.SurfaceKHR) -> vk.PhysicalDevice {
	device_count: u32
	vk.EnumeratePhysicalDevices(instance, &device_count, nil)
	assert(device_count != 0, "failed to find GPUs with vulkan support")

	physical_devices := make([]vk.PhysicalDevice, device_count)
	defer delete(physical_devices)

	vk.EnumeratePhysicalDevices(instance, &device_count, raw_data(physical_devices))

	best_score := -1
	best_device: vk.PhysicalDevice = nil

	for device in physical_devices {
		score := score_physical_device(device, surface)

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

create_logical_device :: proc(
	physical_device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
) -> (
	vk.Device,
	vk.Queue,
) {
	queue_index, ok := get_queue_families(physical_device, {.GRAPHICS}, surface)
	assert(ok, "no graphics queue found on physical device")

	queue_priority: f32 = 0.5
	queue_ci := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = queue_index,
		queueCount       = 1,
		pQueuePriorities = &queue_priority,
	}

	df_extended_dynamic_state := vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT {
		sType                = .PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT,
		extendedDynamicState = true,
	}

	df_vulkan13 := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		dynamicRendering = true,
		pNext            = &df_extended_dynamic_state,
	}

	df_vulkan11 := vk.PhysicalDeviceVulkan11Features {
		sType                = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		shaderDrawParameters = true,
		pNext                = &df_vulkan13,
	}

	df_2 := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &df_vulkan11,
	}

	logical_device_ci := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pQueueCreateInfos       = &queue_ci,
		queueCreateInfoCount    = 1,
		enabledExtensionCount   = u32(len(VK_Required_Extensions)),
		ppEnabledExtensionNames = raw_data(VK_Required_Extensions),
		pNext                   = &df_2,
	}

	logical_device: vk.Device
	result := vk.CreateDevice(physical_device, &logical_device_ci, nil, &logical_device)
	assert(result == .SUCCESS, "failed to create logical device")

	queue: vk.Queue
	vk.GetDeviceQueue(logical_device, queue_index, 0, &queue)

	return logical_device, queue
}

create_surface :: proc(instance: vk.Instance, window: Window) -> vk.SurfaceKHR {
	surface: vk.SurfaceKHR
	ok := glfw.CreateWindowSurface(instance, window.handle, nil, &surface)

	return surface
}

// ------------------------------------------------------------------------ GLFW

init_glfw :: proc() {
	if !glfw.Init() {
		fmt.eprintln("failed to initialize glfw")
		os.exit(1)
	} else {
		fmt.println("initialized glfw")
	}
}

Window :: struct {
	handle: glfw.WindowHandle,
	width:  u32,
	height: u32,
}

create_window :: proc(width: u32, height: u32) -> Window {
	glfw.WindowHint(glfw.RESIZABLE, 0)
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)

	handle := glfw.CreateWindow(i32(width), i32(height), "Vulkan Tutorial Odin", nil, nil)
	assert(handle != nil, "unable to create window")

	return Window{handle = handle, width = width, height = height}
}

// ----------------------------------------------------------------- APPLICATION

is_running := true

main :: proc() {
	init_glfw()
	defer glfw.Terminate()
	fmt.println("GLFW initialized")

	instance := create_instance()
	defer vk.DestroyInstance(instance, nil)
	defer vk.DestroyDebugUtilsMessengerEXT(instance, VK_Debug_Messenger, nil)
	fmt.println("Vulkan instance created")
	fmt.println("Vulkan debug messenger created")

	window := create_window(800, 600)
	fmt.println("GLFW window created")

	surface := create_surface(instance, window)
	fmt.println("Vulkan surface created")

	physical_device := pick_physical_device(instance, surface)
	fmt.println("Vulkan physical device picked")

	logical_device, _ := create_logical_device(physical_device, surface)
	defer vk.DestroyDevice(logical_device, nil)
	fmt.println("Vulkan logical device created")

	fmt.println("GLFW and Vulkan initialized")

	key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
		if key == glfw.KEY_ESCAPE {
			is_running = false
		}
	}

	glfw.SetKeyCallback(window.handle, key_callback)

	for !glfw.WindowShouldClose(window.handle) && is_running {
		glfw.PollEvents()
	}
}
