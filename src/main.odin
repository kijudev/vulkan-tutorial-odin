package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "vendor:glfw"
import vk "vendor:vulkan"

// >------------------------------------------------------------------ CONSTANTS

VK_DEBUG_MESSENGER: vk.DebugUtilsMessengerEXT = {}
VK_DEBUG_LEVEL: vk.DebugUtilsMessageSeverityFlagsEXT = {.WARNING, .ERROR}
VK_VALIDATION_LAYERS := []cstring{"VK_LAYER_KHRONOS_validation"}
VK_REQUIRED_EXTENSIONS := []cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}
VK_NUM_FRAMES_IN_FLIGHT :: 2


// >--------------------------------------------------------------- VULKAN UTILS

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

	if .ERROR in messageSeverity && .ERROR in VK_DEBUG_LEVEL {
		fmt.eprintfln("[validation ERROR] %s", pCallbackData.pMessage)
	} else if .WARNING in messageSeverity && .WARNING in VK_DEBUG_LEVEL {
		fmt.eprintfln("[validation WARNING] %s", pCallbackData.pMessage)
	} else if .INFO in messageSeverity && .INFO in VK_DEBUG_LEVEL {
		fmt.println("[validation INFO]", pCallbackData.pMessage)
	} else if .VERBOSE in messageSeverity && .VERBOSE in VK_DEBUG_LEVEL {
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

		for extension in VK_REQUIRED_EXTENSIONS {
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
	if !features.vulkan13.synchronization2 {
		fmt.printfln("  %q - missing synchronization2 (skipped)", name)
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

choose_swap_extent :: proc(
	capabilities: vk.SurfaceCapabilitiesKHR,
	window: Window,
) -> vk.Extent2D {
	// If the extent is NOT the max value of u32,
	// it has been chosen by the window compositor.
	if capabilities.currentExtent.width != max(u32) {
		return capabilities.currentExtent
	}

	// Otherwise use the framebuffer size in pixels, which can differ
	// from the window size in screen coordinates (e.g. HiDPI scaling).
	fb_width, fb_height := glfw.GetFramebufferSize(window.handle)

	return vk.Extent2D {
		width = clamp(
			u32(fb_width),
			capabilities.minImageExtent.width,
			capabilities.maxImageExtent.width,
		),
		height = clamp(
			u32(fb_height),
			capabilities.minImageExtent.height,
			capabilities.maxImageExtent.height,
		),
	}
}

choose_swap_min_image_count :: proc(capabilities: vk.SurfaceCapabilitiesKHR) -> u32 {
	count := max(3, capabilities.minImageCount)

	if 0 < capabilities.maxImageCount && capabilities.maxImageCount < count {
		count = capabilities.maxImageCount
	}

	return count
}

get_surface_formats :: proc(
	physical_device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
) -> []vk.SurfaceFormatKHR {
	count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &count, nil)
	assert(count > 0, "no surface formats available")

	formats := make([]vk.SurfaceFormatKHR, count)
	vk.GetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &count, raw_data(formats))

	return formats
}

choose_swap_surface_format :: proc(formats: []vk.SurfaceFormatKHR) -> vk.SurfaceFormatKHR {
	for format in formats {
		if format.format == .B8G8R8A8_SRGB && format.colorSpace == .SRGB_NONLINEAR {
			return format
		}
	}

	return formats[0]
}

get_present_modes :: proc(
	physical_device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
) -> []vk.PresentModeKHR {
	count: u32
	vk.GetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &count, nil)
	assert(count > 0, "no preset modes available")

	modes := make([]vk.PresentModeKHR, count)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(physical_device, surface, &count, raw_data(modes))

	return modes
}

choose_present_mode :: proc(modes: []vk.PresentModeKHR) -> vk.PresentModeKHR {
	for mode in modes {
		if mode == .MAILBOX {
			return mode
		}
	}

	return .FIFO
}

create_command_pool :: proc(
	logical_device: vk.Device,
	physical_device: vk.PhysicalDevice,
) -> vk.CommandPool {
	queue_index, ok := get_queue_families(physical_device, {.GRAPHICS}, 0)
	assert(ok, "failed to find queue index for graphics")

	command_pool_ci := vk.CommandPoolCreateInfo {
		sType            = .COMMAND_POOL_CREATE_INFO,
		flags            = {.RESET_COMMAND_BUFFER},
		queueFamilyIndex = queue_index,
	}

	command_pool: vk.CommandPool
	command_pool_result := vk.CreateCommandPool(
		logical_device,
		&command_pool_ci,
		nil,
		&command_pool,
	)

	assert(command_pool_result == .SUCCESS, "failed to create command pool")

	return command_pool
}

create_command_buffer :: proc(
	logical_device: vk.Device,
	command_pool: vk.CommandPool,
) -> vk.CommandBuffer {
	allocation_i := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}

	command_buffers := make([]vk.CommandBuffer, 1)
	command_buffers_result := vk.AllocateCommandBuffers(
		logical_device,
		&allocation_i,
		raw_data(command_buffers),
	)

	assert(command_buffers_result == .SUCCESS, "failed to create command buffers")

	return command_buffers[0]
}

create_command_buffers :: proc(
	logical_device: vk.Device,
	command_pool: vk.CommandPool,
	command_buffers: []vk.CommandBuffer,
) {
	allocation_i := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = command_pool,
		level              = .PRIMARY,
		commandBufferCount = u32(len(command_buffers)),
	}

	command_buffers_result := vk.AllocateCommandBuffers(
		logical_device,
		&allocation_i,
		raw_data(command_buffers),
	)

	assert(command_buffers_result == .SUCCESS, "failed to create command buffers")
}

begin_command_buffer :: proc(command_buffer: vk.CommandBuffer) {
	begin_i := vk.CommandBufferBeginInfo {
		sType            = .COMMAND_BUFFER_BEGIN_INFO,
		flags            = {},
		pInheritanceInfo = nil,
	}

	result := vk.BeginCommandBuffer(command_buffer, &begin_i)
	assert(result == .SUCCESS, "failed to begin command buffer")
}

transition_image_layout :: proc(
	command_buffer: vk.CommandBuffer,
	image: vk.Image,
	old_layout: vk.ImageLayout,
	new_layout: vk.ImageLayout,
	src_access_mask: vk.AccessFlags2,
	dst_access_mask: vk.AccessFlags2,
	src_stage_mask: vk.PipelineStageFlags2,
	dst_stage_mask: vk.PipelineStageFlags2,
) {

	image_barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = src_stage_mask,
		srcAccessMask = src_access_mask,
		dstStageMask = dst_stage_mask,
		dstAccessMask = dst_access_mask,
		oldLayout = old_layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = vk.ImageSubresourceRange {
			aspectMask = {.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}

	dependency_i := vk.DependencyInfo {
		sType                    = .DEPENDENCY_INFO,
		dependencyFlags          = {},
		memoryBarrierCount       = 0,
		pMemoryBarriers          = nil,
		bufferMemoryBarrierCount = 0,
		pBufferMemoryBarriers    = nil,
		imageMemoryBarrierCount  = 1,
		pImageMemoryBarriers     = &image_barrier,
	}

	vk.CmdPipelineBarrier2(command_buffer, &dependency_i)
}

begin_rendering :: proc(
	command_buffer: vk.CommandBuffer,
	image_view: vk.ImageView,
	swap_chain_extent: vk.Extent2D,
) {
	attachment_i := vk.RenderingAttachmentInfo {
		sType = .RENDERING_ATTACHMENT_INFO,
		imageView = image_view,
		imageLayout = .COLOR_ATTACHMENT_OPTIMAL,
		loadOp = .CLEAR,
		storeOp = .STORE,
		clearValue = {color = {float32 = {0.0, 0.0, 0.0, 1.0}}},
	}

	render_i := vk.RenderingInfo {
		sType = .RENDERING_INFO,
		layerCount = 1,
		renderArea = {extent = swap_chain_extent},
		pColorAttachments = &attachment_i,
		colorAttachmentCount = 1,
	}

	vk.CmdBeginRendering(command_buffer, &render_i)
}

set_viewport :: proc(command_buffer: vk.CommandBuffer, swap_chain_extent: vk.Extent2D) {
	viewport := vk.Viewport {
		x        = 0,
		y        = 0,
		width    = f32(swap_chain_extent.width),
		height   = f32(swap_chain_extent.height),
		minDepth = 0.0,
		maxDepth = 1.0,
	}

	vk.CmdSetViewport(command_buffer, 0, 1, &viewport)
}

set_scissor :: proc(command_buffer: vk.CommandBuffer, swap_chain_extent: vk.Extent2D) {
	scissor := vk.Rect2D {
		offset = {x = 0, y = 0},
		extent = {swap_chain_extent.width, swap_chain_extent.height},
	}

	vk.CmdSetScissor(command_buffer, 0, 1, &scissor)
}


end_rendering :: proc(command_buffer: vk.CommandBuffer) {
	vk.CmdEndRendering(command_buffer)
}


end_command_buffer :: proc(command_buffer: vk.CommandBuffer) {
	result := vk.EndCommandBuffer(command_buffer)
	assert(result == .SUCCESS, "failed to end command buffer")
}

create_semaphore :: proc(logical_device: vk.Device) -> vk.Semaphore {
	semaphore_ci := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
		flags = {},
	}

	semaphore: vk.Semaphore
	semaphore_result := vk.CreateSemaphore(logical_device, &semaphore_ci, nil, &semaphore)
	assert(semaphore_result == .SUCCESS, "failed to create semaphore")

	return semaphore
}

create_semaphores :: proc(logical_device: vk.Device, semaphores: []vk.Semaphore) {
	for i in 0 ..< len(semaphores) {
		semaphores[i] = create_semaphore(logical_device)
	}
}

create_fence :: proc(logical_device: vk.Device) -> vk.Fence {
	fence_ci := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {.SIGNALED},
	}

	fence: vk.Fence
	fence_result := vk.CreateFence(logical_device, &fence_ci, nil, &fence)
	assert(fence_result == .SUCCESS, "failed to create fence")

	return fence
}

create_fences :: proc(logical_device: vk.Device, fences: []vk.Fence) {
	for i in 0 ..< len(fences) {
		fences[i] = create_fence(logical_device)
	}
}

wait_for_fence :: proc(logical_device: vk.Device, fence: vk.Fence) {
	fence := fence
	fence_result := vk.WaitForFences(logical_device, 1, &fence, true, max(u64))
	assert(fence_result == .SUCCESS, "failed to wait for fence")
}

reset_fence :: proc(logical_device: vk.Device, fence: vk.Fence) {
	fence := fence
	fence_result := vk.ResetFences(logical_device, 1, &fence)
	assert(fence_result == .SUCCESS, "failed to wait for fence")
}

Acquire_Flag :: enum {
	Acquired, // An image was acquired and must be drawn and presented
	Needs_Recreation, // The swap chain no longer matches the surface
}

Acquire_Flags :: bit_set[Acquire_Flag]

acquire_next_image :: proc(
	logical_device: vk.Device,
	swap_chain: vk.SwapchainKHR,
	draw_fence: vk.Fence,
	acquire_semaphore: vk.Semaphore,
) -> (
	image_index: u32,
	flags: Acquire_Flags,
) {
	wait_for_fence(logical_device, draw_fence)

	result := vk.AcquireNextImageKHR(
		logical_device,
		swap_chain,
		max(u64),
		acquire_semaphore,
		0,
		&image_index,
	)

	#partial switch result {
	case .SUCCESS:
		return image_index, {.Acquired}
	case .SUBOPTIMAL_KHR:
		// The image is still valid: draw it, then recreate
		return image_index, {.Acquired, .Needs_Recreation}
	case .ERROR_OUT_OF_DATE_KHR:
		// No image was acquired
		return 0, {.Needs_Recreation}
	}

	panic("failed to acquire next image")
}

destroy_swap_chain :: proc(logical_device: vk.Device, swap_chain: vk.SwapchainKHR) {
	if swap_chain != 0 {
		vk.DestroySwapchainKHR(logical_device, swap_chain, nil)
	}
}

destroy_swap_chain_images :: proc(logical_device: vk.Device, swap_chain_images: []vk.Image) {
	if swap_chain_images != nil {
		delete(swap_chain_images)
	}
}


destroy_swap_chain_image_views :: proc(
	logical_device: vk.Device,
	swap_chain_image_views: []vk.ImageView,
) {
	if swap_chain_image_views != nil {
		for image_view in swap_chain_image_views {
			vk.DestroyImageView(logical_device, image_view, nil)
		}

		delete(swap_chain_image_views)
	}
}

// >--------------------------------------------------------------- VULKAN SETUP


create_instance :: proc() -> vk.Instance {
	vk.load_proc_addresses(rawptr(glfw.GetInstanceProcAddress))
	ok := check_layer_support(VK_VALIDATION_LAYERS)
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
		messageSeverity = VK_DEBUG_LEVEL,
		messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = debug_callback,
		pUserData       = nil,
	}

	instance_ci := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &application_i,
		enabledExtensionCount   = u32(len(extension_names)),
		ppEnabledExtensionNames = raw_data(extension_names[:]),
		enabledLayerCount       = u32(len(VK_VALIDATION_LAYERS)),
		ppEnabledLayerNames     = raw_data(VK_VALIDATION_LAYERS),
		pNext                   = &debug_ci,
	}

	instance: vk.Instance
	create_instance_result := vk.CreateInstance(&instance_ci, nil, &instance)
	assert(create_instance_result == .SUCCESS, "failed to create instance")

	fmt.println("VK: instance created")

	vk.load_proc_addresses_instance(instance)

	if vk.CreateDebugUtilsMessengerEXT != nil {
		ok := vk.CreateDebugUtilsMessengerEXT(instance, &debug_ci, nil, &VK_DEBUG_MESSENGER)
		assert(ok == .SUCCESS, "failed to create debug messenger")
	}

	return instance
}

choose_physical_device :: proc(
	instance: vk.Instance,
	surface: vk.SurfaceKHR,
) -> vk.PhysicalDevice {
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
		synchronization2 = true,
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
		enabledExtensionCount   = u32(len(VK_REQUIRED_EXTENSIONS)),
		ppEnabledExtensionNames = raw_data(VK_REQUIRED_EXTENSIONS),
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

create_swap_chain :: proc(
	physical_device: vk.PhysicalDevice,
	logical_device: vk.Device,
	surface: vk.SurfaceKHR,
	window: Window,
) -> (
	vk.SwapchainKHR,
	vk.Format,
	vk.Extent2D,
) {
	surface_capabilities: vk.SurfaceCapabilitiesKHR
	surface_result := vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
		physical_device,
		surface,
		&surface_capabilities,
	)

	assert(surface_result == .SUCCESS, "failed to get surface capabilities")

	extent := choose_swap_extent(surface_capabilities, window)
	min_image_count := choose_swap_min_image_count(surface_capabilities)

	formats := get_surface_formats(physical_device, surface)
	defer delete(formats)

	format := choose_swap_surface_format(formats)
	preset_modes := get_present_modes(physical_device, surface)
	defer delete(preset_modes)

	present_mode := choose_present_mode(preset_modes)

	swap_chain_ci := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = surface,
		minImageCount    = min_image_count,
		imageFormat      = format.format,
		imageColorSpace  = format.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = surface_capabilities.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = present_mode,
		clipped          = true,
	}

	swap_chain: vk.SwapchainKHR
	swap_chain_result := vk.CreateSwapchainKHR(logical_device, &swap_chain_ci, nil, &swap_chain)
	assert(swap_chain_result == .SUCCESS, "failed to create swap chain")

	return swap_chain, format.format, extent
}

get_swap_chain_images :: proc(
	logical_device: vk.Device,
	swap_chain: vk.SwapchainKHR,
) -> []vk.Image {
	count: u32
	vk.GetSwapchainImagesKHR(logical_device, swap_chain, &count, nil)
	assert(count > 0, "no swap chain images are available")

	images := make([]vk.Image, count)
	vk.GetSwapchainImagesKHR(logical_device, swap_chain, &count, raw_data(images))

	return images
}

create_image_views :: proc(
	logical_device: vk.Device,
	images: []vk.Image,
	format: vk.Format,
) -> []vk.ImageView {
	image_view_ci := vk.ImageViewCreateInfo {
		sType            = .IMAGE_VIEW_CREATE_INFO,
		viewType         = .D2,
		format           = format,
		subresourceRange = {{.COLOR}, 0, 1, 0, 1},
	}

	image_views := make([]vk.ImageView, len(images))
	for image, i in images {
		image_view_ci.image = image
		result := vk.CreateImageView(logical_device, &image_view_ci, nil, &image_views[i])
		assert(result == .SUCCESS, "failed to create image view")
	}

	return image_views
}

create_shader_module :: proc(
	logical_device: vk.Device,
	slang_path: string,
	entry_points: []string,
) -> vk.ShaderModule {
	spv, ok := compile_slang_shader(slang_path, entry_points)
	assert(ok, "shader compilation failed")

	defer delete(spv)

	shader_module_ci := vk.ShaderModuleCreateInfo {
		sType    = .SHADER_MODULE_CREATE_INFO,
		codeSize = len(spv),
		pCode    = raw_data(slice.reinterpret([]u32, spv)),
	}

	shader_module: vk.ShaderModule
	result := vk.CreateShaderModule(logical_device, &shader_module_ci, nil, &shader_module)
	assert(result == .SUCCESS, "failed to create shader module")

	return shader_module
}

create_graphics_pipeline :: proc(
	logical_device: vk.Device,
	shader_module: vk.ShaderModule,
	vertex_entry: string,
	fragment_entry: string,
	swap_chain_format: vk.Format,
) -> (
	vk.Pipeline,
	vk.PipelineLayout,
) {
	vertex_entry_cstring := strings.clone_to_cstring(vertex_entry)
	defer delete(vertex_entry_cstring)

	fragment_entry_cstring := strings.clone_to_cstring(fragment_entry)
	defer delete(fragment_entry_cstring)

	shaders_ci := []vk.PipelineShaderStageCreateInfo {
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.VERTEX},
			module = shader_module,
			pName = vertex_entry_cstring,
		},
		{
			sType = .PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {.FRAGMENT},
			module = shader_module,
			pName = fragment_entry_cstring,
		},
	}

	// What can be dynamic in the pipeline.
	// What things can be mutated without creating a new pipeline.
	dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state_ci := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = raw_data(dynamic_states),
	}

	// Vertex input.
	// Configure the data format of vertices.
	// For now the vertices are hardcoded in shaders themselves.
	vertex_input_ci := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 0,
		pVertexBindingDescriptions      = nil,
		vertexAttributeDescriptionCount = 0,
		pVertexAttributeDescriptions    = nil,
	}

	// Input assembly.
	// Configure topology.
	input_assembly_ci := vk.PipelineInputAssemblyStateCreateInfo {
		sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology               = .TRIANGLE_LIST,
		primitiveRestartEnable = false,
	}

	// These are dynamic as set previously.
	viewport_state_ci := vk.PipelineViewportStateCreateInfo {
		sType         = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		scissorCount  = 1,
	}

	rasterizer_ci := vk.PipelineRasterizationStateCreateInfo {
		sType                   = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable        = false,
		rasterizerDiscardEnable = false,
		polygonMode             = .FILL,
		cullMode                = {.BACK},
		frontFace               = .CLOCKWISE,
		depthBiasEnable         = false,
		lineWidth               = 1,
	}

	multisampling_ci := vk.PipelineMultisampleStateCreateInfo {
		sType                 = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		sampleShadingEnable   = false,
		rasterizationSamples  = {._1},
		minSampleShading      = 1,
		pSampleMask           = nil,
		alphaToCoverageEnable = false,
		alphaToOneEnable      = false,
	}

	color_blend_attachment := vk.PipelineColorBlendAttachmentState {
		blendEnable         = true,
		srcColorBlendFactor = .SRC_ALPHA,
		dstColorBlendFactor = .ONE_MINUS_SRC_ALPHA,
		colorBlendOp        = .ADD,
		srcAlphaBlendFactor = .ONE,
		dstAlphaBlendFactor = .ZERO,
		alphaBlendOp        = .ADD,
		colorWriteMask      = {.R, .G, .B, .A},
	}

	color_blend_ci := vk.PipelineColorBlendStateCreateInfo {
		sType           = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable   = false,
		logicOp         = .COPY,
		attachmentCount = 1,
		pAttachments    = &color_blend_attachment,
	}

	pipeline_layout_ci := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 0,
		pSetLayouts            = nil,
		pushConstantRangeCount = 0,
		pPushConstantRanges    = nil,
	}

	pipeline_layout: vk.PipelineLayout
	pipeline_layout_result := vk.CreatePipelineLayout(
		logical_device,
		&pipeline_layout_ci,
		nil,
		&pipeline_layout,
	)

	assert(pipeline_layout_result == .SUCCESS, "failed to create pipeline layout")

	format := swap_chain_format
	pipeline_rendering_ci := vk.PipelineRenderingCreateInfo {
		sType                   = .PIPELINE_RENDERING_CREATE_INFO,
		colorAttachmentCount    = 1,
		pColorAttachmentFormats = &format,
	}

	pipeline_ci := vk.GraphicsPipelineCreateInfo {
		sType               = .GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = 2,
		pStages             = raw_data(shaders_ci),
		pVertexInputState   = &vertex_input_ci,
		pInputAssemblyState = &input_assembly_ci,
		pViewportState      = &viewport_state_ci,
		pRasterizationState = &rasterizer_ci,
		pMultisampleState   = &multisampling_ci,
		pColorBlendState    = &color_blend_ci,
		pDynamicState       = &dynamic_state_ci,
		layout              = pipeline_layout,
		renderPass          = 0,
		pNext               = &pipeline_rendering_ci,
	}

	graphics_pipeline: vk.Pipeline
	graphics_pipeline_result := vk.CreateGraphicsPipelines(
		logical_device,
		0,
		1,
		&pipeline_ci,
		nil,
		&graphics_pipeline,
	)

	assert(graphics_pipeline_result == .SUCCESS, "failed to create graphics pipeline")

	return graphics_pipeline, pipeline_layout
}

record_command_buffer :: proc(
	command_buffer: vk.CommandBuffer,
	image: vk.Image,
	image_view: vk.ImageView,
	swap_chain_extent: vk.Extent2D,
	graphics_pipeline: vk.Pipeline,
) {

	// Begin to start the recording...
	begin_command_buffer(command_buffer)

	// Transfert the image to ColorAttachmentOptimal
	transition_image_layout(
		command_buffer,
		image,
		.UNDEFINED,
		.COLOR_ATTACHMENT_OPTIMAL,
		{}, // srcAccessMask
		{.COLOR_ATTACHMENT_WRITE}, // dstAccessMask
		{.COLOR_ATTACHMENT_OUTPUT}, // srcStage
		{.COLOR_ATTACHMENT_OUTPUT}, // dstStage
	)

	// Start rendering
	begin_rendering(command_buffer, image_view, swap_chain_extent)

	// We can now bind the graphics pipeline
	vk.CmdBindPipeline(command_buffer, .GRAPHICS, graphics_pipeline)

	// Set viewport
	set_viewport(command_buffer, swap_chain_extent)

	// Set scissor
	set_scissor(command_buffer, swap_chain_extent)

	// Draw 3 vertices
	vk.CmdDraw(command_buffer, 3, 1, 0, 0)

	// End the rendering
	end_rendering(command_buffer)

	// After rendering, we need to
	// transition the image layout to PresentSrcKHR so it can be
	// displayed on the screen.
	transition_image_layout(
		command_buffer,
		image,
		.COLOR_ATTACHMENT_OPTIMAL,
		.PRESENT_SRC_KHR,
		{.COLOR_ATTACHMENT_WRITE}, // srcAccessMask
		{}, // dstAccessMask
		{.COLOR_ATTACHMENT_OUTPUT}, // srcStage
		{.BOTTOM_OF_PIPE}, // dstStage
	)

	end_command_buffer(command_buffer)
}

submit_command_buffer :: proc(
	logical_device: vk.Device,
	command_buffer: vk.CommandBuffer,
	draw_fence: vk.Fence,
	acquire_semaphore: vk.Semaphore,
	render_finish_semaphore: vk.Semaphore,
	graphics_queue: vk.Queue,
) {
	acquire_semaphore := acquire_semaphore
	command_buffer := command_buffer
	render_finish_semaphore := render_finish_semaphore

	wait_dst_stage_mask := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}

	submit_i := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &acquire_semaphore,
		pWaitDstStageMask    = &wait_dst_stage_mask,
		commandBufferCount   = 1,
		pCommandBuffers      = &command_buffer,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &render_finish_semaphore,
	}

	submit_result := vk.QueueSubmit(graphics_queue, 1, &submit_i, draw_fence)
	assert(submit_result == .SUCCESS, "failed to submit command buffer")
}

queue_present :: proc(
	logical_device: vk.Device,
	swap_chain: vk.SwapchainKHR,
	render_finish_semaphore: vk.Semaphore,
	graphics_queue: vk.Queue,
	swap_chain_image_index: u32,
) -> bool {
	swap_chain := swap_chain
	render_finish_semaphore := render_finish_semaphore
	swap_chain_image_index := swap_chain_image_index

	present_i := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		swapchainCount     = 1,
		pSwapchains        = &swap_chain,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &render_finish_semaphore,
		pImageIndices      = &swap_chain_image_index,
	}

	present_result := vk.QueuePresentKHR(graphics_queue, &present_i)


	if present_result == .SUBOPTIMAL_KHR || present_result == .ERROR_OUT_OF_DATE_KHR {
		return true
	}

	assert(present_result == .SUCCESS, "failed to queue present")
	return false
}

wait_idle_device :: proc(logical_device: vk.Device) {
	vk.DeviceWaitIdle(logical_device)
}

// >----------------------------------------------------------------------- GLFW

init_glfw :: proc() {
	result := glfw.Init()
	assert(bool(result), "failed to initialize GLFW")
}

Window :: struct {
	handle: glfw.WindowHandle,
	width:  u32,
	height: u32,
}

create_window :: proc(width: u32, height: u32) -> Window {
	glfw.WindowHint(glfw.RESIZABLE, 1)
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)

	handle := glfw.CreateWindow(i32(width), i32(height), "Vulkan Tutorial Odin", nil, nil)
	assert(handle != nil, "unable to create window")

	return Window{handle = handle, width = width, height = height}
}

// >---------------------------------------------------------------- APPLICATION

is_running: bool = true
is_frambuffer_resized: bool = false

main :: proc() {
	init_glfw()
	defer glfw.Terminate()
	fmt.println("GLFW initialized")

	instance := create_instance()
	defer vk.DestroyInstance(instance, nil)
	defer vk.DestroyDebugUtilsMessengerEXT(instance, VK_DEBUG_MESSENGER, nil)
	fmt.println("Vulkan instance created")
	fmt.println("Vulkan debug messenger created")

	window := create_window(800, 600)
	fmt.println("GLFW window created")

	surface := create_surface(instance, window)
	defer vk.DestroySurfaceKHR(instance, surface, nil)
	fmt.println("Vulkan surface created")

	physical_device := choose_physical_device(instance, surface)
	fmt.println("Vulkan physical device picked")

	logical_device, graphics_queue := create_logical_device(physical_device, surface)
	defer vk.DestroyDevice(logical_device, nil)
	fmt.println("Vulkan logical device created")

	swap_chain, swap_chain_format, swap_chain_extent := create_swap_chain(
		physical_device,
		logical_device,
		surface,
		window,
	)

	defer vk.DestroySwapchainKHR(logical_device, swap_chain, nil)
	fmt.println("Vulkan swap chain created")

	swap_chain_images := get_swap_chain_images(logical_device, swap_chain)
	defer delete(swap_chain_images)
	fmt.println("Vulkan swap chain images available")

	swap_chain_image_views := create_image_views(
		logical_device,
		swap_chain_images,
		swap_chain_format,
	)

	defer {
		for view in swap_chain_image_views {
			vk.DestroyImageView(logical_device, view, nil)
		}

		delete(swap_chain_image_views)
	}

	shader_module := create_shader_module(
		logical_device,
		"shaders/shader.slang",
		{"vertMain", "fragMain"},
	)
	defer vk.DestroyShaderModule(logical_device, shader_module, nil)
	fmt.println("Vulkan shader module created")

	graphics_pipeline, pipeline_layout := create_graphics_pipeline(
		logical_device,
		shader_module,
		"vertMain",
		"fragMain",
		swap_chain_format,
	)
	defer vk.DestroyPipelineLayout(logical_device, pipeline_layout, nil)
	defer vk.DestroyPipeline(logical_device, graphics_pipeline, nil)
	fmt.println("Vulkan pipeline layout created")

	command_pool := create_command_pool(logical_device, physical_device)
	defer vk.DestroyCommandPool(logical_device, command_pool, nil)
	fmt.println("Vulkan command pool created")

	command_buffers: [VK_NUM_FRAMES_IN_FLIGHT]vk.CommandBuffer
	create_command_buffers(logical_device, command_pool, command_buffers[:])
	fmt.println("Vulkan command buffers created")

	acquire_semaphores: [VK_NUM_FRAMES_IN_FLIGHT]vk.Semaphore
	create_semaphores(logical_device, acquire_semaphores[:])

	defer {
		for semaphore in acquire_semaphores {
			vk.DestroySemaphore(logical_device, semaphore, nil)
		}
	}

	fmt.println("Vulkan acquire semaphores created")

	submit_semaphores := make([]vk.Semaphore, len(swap_chain_images))
	create_semaphores(logical_device, submit_semaphores)
	defer delete(submit_semaphores)

	defer {
		for semaphore in submit_semaphores {
			vk.DestroySemaphore(logical_device, semaphore, nil)
		}
	}

	fmt.println("Vulkan submit semaphores created")

	draw_fences: [VK_NUM_FRAMES_IN_FLIGHT]vk.Fence
	create_fences(logical_device, draw_fences[:])

	defer {
		for fence in draw_fences {
			vk.DestroyFence(logical_device, fence, nil)
		}
	}

	fmt.println("Vulkan draw fences created")

	key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
		if key == glfw.KEY_ESCAPE {
			is_running = false
		}
	}

	glfw.SetKeyCallback(window.handle, key_callback)

	framebuffer_resize_callback :: proc "c" (window: glfw.WindowHandle, width: i32, height: i32) {
		is_frambuffer_resized = true
	}

	glfw.SetFramebufferSizeCallback(window.handle, framebuffer_resize_callback)

	frame_index: u32 = 0
	for !glfw.WindowShouldClose(window.handle) && is_running {
		glfw.PollEvents()

		swap_chain_image_index, acquire_flags := acquire_next_image(
			logical_device,
			swap_chain,
			draw_fences[frame_index],
			acquire_semaphores[frame_index],
		)

		is_swap_chain_recreation_needed := .Needs_Recreation in acquire_flags

		if .Acquired in acquire_flags {
			// Only reset once we know a submit will signal it again
			reset_fence(logical_device, draw_fences[frame_index])

			record_command_buffer(
				command_buffers[frame_index],
				swap_chain_images[swap_chain_image_index],
				swap_chain_image_views[swap_chain_image_index],
				swap_chain_extent,
				graphics_pipeline,
			)

			submit_command_buffer(
				logical_device,
				command_buffers[frame_index],
				draw_fences[frame_index],
				acquire_semaphores[frame_index],
				submit_semaphores[swap_chain_image_index],
				graphics_queue,
			)

			is_swap_chain_recreation_needed |= queue_present(
				logical_device,
				swap_chain,
				submit_semaphores[swap_chain_image_index],
				graphics_queue,
				swap_chain_image_index,
			)
		}

		if is_swap_chain_recreation_needed || is_frambuffer_resized {
			width, height := glfw.GetFramebufferSize(window.handle)
			for width == 0 && height == 0 {
				glfw.WaitEvents()
				width, height = glfw.GetFramebufferSize(window.handle)
			}

			window.width = u32(width)
			window.height = u32(height)

			is_frambuffer_resized = false
			wait_idle_device(logical_device)

			destroy_swap_chain_image_views(logical_device, swap_chain_image_views)
			destroy_swap_chain_images(logical_device, swap_chain_images)
			destroy_swap_chain(logical_device, swap_chain)

			swap_chain, swap_chain_format, swap_chain_extent = create_swap_chain(
				physical_device,
				logical_device,
				surface,
				window,
			)

			swap_chain_images = get_swap_chain_images(logical_device, swap_chain)
			swap_chain_image_views = create_image_views(
				logical_device,
				swap_chain_images,
				swap_chain_format,
			)

			for semaphore in submit_semaphores {
				vk.DestroySemaphore(logical_device, semaphore, nil)
			}

			delete(submit_semaphores)

			submit_semaphores = make([]vk.Semaphore, len(swap_chain_images))
			create_semaphores(logical_device, submit_semaphores)

			fmt.println("Vulkan swap chain crecreated")
		}


		frame_index = (frame_index + 1) % VK_NUM_FRAMES_IN_FLIGHT
	}

	wait_idle_device(logical_device)
}
