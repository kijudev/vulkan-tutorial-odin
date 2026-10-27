package main

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:image"
import "core:image/jpeg"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "vendor:glfw"
import vk "vendor:vulkan"

_ :: jpeg

// >------------------------------------------------------------------ CONSTANTS

VK_DEBUG_MESSENGER: vk.DebugUtilsMessengerEXT = {}
VK_DEBUG_LEVEL: vk.DebugUtilsMessageSeverityFlagsEXT = {.WARNING, .ERROR}
VK_VALIDATION_LAYERS := []cstring{"VK_LAYER_KHRONOS_validation"}
VK_REQUIRED_EXTENSIONS := []cstring{vk.KHR_SWAPCHAIN_EXTENSION_NAME}
VK_NUM_FRAMES_IN_FLIGHT :: 2

// >---------------------------------------------------------------------- TYPES

vec2 :: [2]f32
vec3 :: [3]f32
mat4 :: matrix[4, 4]f32

Vertex :: struct {
	pos:   vec2,
	color: vec3,
}

Uniform_Buffer_Object :: struct {
	model: mat4,
	view:  mat4,
	proj:  mat4,
}

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

	if !features.default.samplerAnisotropy {
		fmt.println("missing samplerAnisotropy")
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

begin_command_buffer :: proc(
	command_buffer: vk.CommandBuffer,
	flags: vk.CommandBufferUsageFlags = {},
) {
	begin_i := vk.CommandBufferBeginInfo {
		sType            = .COMMAND_BUFFER_BEGIN_INFO,
		flags            = flags,
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

transfer_to_buffer :: proc(
	physical_device: vk.PhysicalDevice,
	logical_device: vk.Device,
	queue: vk.Queue,
	data: []$T,
	dest: vk.Buffer,
) {
	size := u64(len(data) * size_of(T))

	staging_buffer, staging_buffer_memory := create_buffer(
		physical_device,
		logical_device,
		size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)

	defer vk.DestroyBuffer(logical_device, staging_buffer, nil)
	defer vk.FreeMemory(logical_device, staging_buffer_memory, nil)

	memory_copy_to_buffer(logical_device, staging_buffer_memory, data)

	command_pool := create_command_pool(logical_device, physical_device)
	defer vk.DestroyCommandPool(logical_device, command_pool, nil)

	command_buffers: [1]vk.CommandBuffer
	create_command_buffers(logical_device, command_pool, command_buffers[:])
	command_buffer := command_buffers[0]

	begin_command_buffer(command_buffer, {.ONE_TIME_SUBMIT})

	copy_region := vk.BufferCopy {
		srcOffset = 0,
		dstOffset = 0,
		size      = vk.DeviceSize(size),
	}

	vk.CmdCopyBuffer(command_buffer, staging_buffer, dest, 1, &copy_region)
	end_command_buffer(command_buffer)

	submit_i := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &command_buffer,
	}

	submit_result := vk.QueueSubmit(queue, 1, &submit_i, 0)
	assert(submit_result == .SUCCESS, "failed to submit queue")

	wait_result := vk.QueueWaitIdle(queue)
	assert(wait_result == .SUCCESS, "failed to wait for queue idle")
}


transfer_buffer_to_image :: proc(
	command_buffer: vk.CommandBuffer,
	src_buffer: vk.Buffer,
	dest_image: vk.Image,
	width: u32,
	height: u32,
) {
	copy_region := vk.BufferImageCopy {
		bufferOffset = 0,
		bufferRowLength = 0,
		bufferImageHeight = 0,
		imageSubresource = {
			aspectMask = {.COLOR},
			mipLevel = 0,
			baseArrayLayer = 0,
			layerCount = 1,
		},
		imageOffset = {0, 0, 0},
		imageExtent = {width, height, 1},
	}

	vk.CmdCopyBufferToImage(
		command_buffer,
		src_buffer,
		dest_image,
		.TRANSFER_DST_OPTIMAL,
		1,
		&copy_region,
	)
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
		features = {samplerAnisotropy = true},
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

create_image_view :: proc(
	logical_device: vk.Device,
	image: vk.Image,
	format: vk.Format,
) -> vk.ImageView {
	image_view_ci := vk.ImageViewCreateInfo {
		sType            = .IMAGE_VIEW_CREATE_INFO,
		viewType         = .D2,
		format           = format,
		subresourceRange = {{.COLOR}, 0, 1, 0, 1},
		image            = image,
	}

	image_view: vk.ImageView
	image_view_result := vk.CreateImageView(logical_device, &image_view_ci, nil, &image_view)
	assert(image_view_result == .SUCCESS, "failed to create an image view")

	return image_view
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
	descriptor_set_layout: vk.DescriptorSetLayout,
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

	dynamic_states := []vk.DynamicState{.VIEWPORT, .SCISSOR}
	dynamic_state_ci := vk.PipelineDynamicStateCreateInfo {
		sType             = .PIPELINE_DYNAMIC_STATE_CREATE_INFO,
		dynamicStateCount = u32(len(dynamic_states)),
		pDynamicStates    = raw_data(dynamic_states),
	}

	vertex_binding_description := vk.VertexInputBindingDescription {
		binding   = 0,
		stride    = size_of(Vertex),
		inputRate = .VERTEX,
	}

	vertex_attribute_description := []vk.VertexInputAttributeDescription {
		{location = 0, binding = 0, format = .R32G32_SFLOAT, offset = u32(offset_of(Vertex, pos))},
		{
			location = 1,
			binding = 0,
			format = .R32G32B32_SFLOAT,
			offset = u32(offset_of(Vertex, color)),
		},
	}

	vertex_input_ci := vk.PipelineVertexInputStateCreateInfo {
		sType                           = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
		vertexBindingDescriptionCount   = 1,
		pVertexBindingDescriptions      = &vertex_binding_description,
		vertexAttributeDescriptionCount = u32(len(vertex_attribute_description)),
		pVertexAttributeDescriptions    = raw_data(vertex_attribute_description),
	}

	input_assembly_ci := vk.PipelineInputAssemblyStateCreateInfo {
		sType                  = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology               = .TRIANGLE_LIST,
		primitiveRestartEnable = false,
	}

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
		frontFace               = .COUNTER_CLOCKWISE,
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

	descriptor_set_layout := descriptor_set_layout
	pipeline_layout_ci := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount         = 1,
		pSetLayouts            = &descriptor_set_layout,
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
	pipeline_layout: vk.PipelineLayout,
	vertex_buffer: vk.Buffer,
	index_buffer: vk.Buffer,
	index_count: u32,
	descriptor_set: vk.DescriptorSet,
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

	// Bind vertex buffer to binding 0
	offsets := vk.DeviceSize(0)
	vertex_buffer := vertex_buffer
	vk.CmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffer, &offsets)

	vk.CmdBindIndexBuffer(command_buffer, index_buffer, vk.DeviceSize(0), .UINT16)

	descriptor_set := descriptor_set
	vk.CmdBindDescriptorSets(
		command_buffer,
		.GRAPHICS,
		pipeline_layout,
		0,
		1,
		&descriptor_set,
		0,
		nil,
	)

	// Replaced by CmdDrawIndexed
	// vk.CmdDraw(command_buffer, 3, 1, 0, 0)

	vk.CmdDrawIndexed(command_buffer, index_count, 1, 0, 0, 0)

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

create_buffer :: proc(
	physical_device: vk.PhysicalDevice,
	logical_device: vk.Device,
	size: u64,
	usage_flags: vk.BufferUsageFlags,
	property_flags: vk.MemoryPropertyFlags,
) -> (
	vk.Buffer,
	vk.DeviceMemory,
) {
	buffer_ci := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = vk.DeviceSize(size),
		usage       = usage_flags,
		sharingMode = .EXCLUSIVE,
	}

	buffer: vk.Buffer
	buffer_result := vk.CreateBuffer(logical_device, &buffer_ci, nil, &buffer)
	assert(buffer_result == .SUCCESS, "failed to create buffer")

	memory_requirenments: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(logical_device, buffer, &memory_requirenments)

	memory_type_index, ok := find_memory_type(
		physical_device,
		memory_requirenments.memoryTypeBits,
		property_flags,
	)

	assert(ok, "failed to find memory type")

	allocation_i := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = memory_requirenments.size,
		memoryTypeIndex = memory_type_index,
	}

	buffer_memory: vk.DeviceMemory
	allocate_result := vk.AllocateMemory(logical_device, &allocation_i, nil, &buffer_memory)
	assert(allocate_result == .SUCCESS, "failed to allocate buffer memory")

	bind_result := vk.BindBufferMemory(logical_device, buffer, buffer_memory, 0)
	assert(bind_result == .SUCCESS, "failed to bind buffer memory")

	return buffer, buffer_memory
}


find_memory_type :: proc(
	physical_device: vk.PhysicalDevice,
	type_filter: u32,
	properties: vk.MemoryPropertyFlags,
) -> (
	u32,
	bool,
) {
	mem_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(physical_device, &mem_properties)

	for i in 0 ..< mem_properties.memoryTypeCount {
		if (type_filter & (1 << i)) != 0 &&
		   (mem_properties.memoryTypes[i].propertyFlags & properties) == properties {
			return i, true
		}
	}


	return 0, false
}

memory_copy_to_buffer :: proc(
	logical_device: vk.Device,
	buffer_memory: vk.DeviceMemory,
	data: []$T,
) {
	size := size_of(T) * len(data)
	dest_data: rawptr

	map_result := vk.MapMemory(
		logical_device,
		buffer_memory,
		0,
		vk.DeviceSize(size),
		{},
		&dest_data,
	)

	assert(map_result == .SUCCESS, "failed to map memory")
	mem.copy(dest_data, raw_data(data), size)
	vk.UnmapMemory(logical_device, buffer_memory)
}


create_descriptor_set_layout :: proc(logical_device: vk.Device) -> vk.DescriptorSetLayout {
	layout_binding := vk.DescriptorSetLayoutBinding {
		binding         = 0,
		descriptorType  = .UNIFORM_BUFFER,
		descriptorCount = 1,
		stageFlags      = {.VERTEX},
	}

	layout_ci := vk.DescriptorSetLayoutCreateInfo {
		sType        = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings    = &layout_binding,
	}

	descriptor_set_layout: vk.DescriptorSetLayout
	descriptor_set_layout_result := vk.CreateDescriptorSetLayout(
		logical_device,
		&layout_ci,
		nil,
		&descriptor_set_layout,
	)

	assert(descriptor_set_layout_result == .SUCCESS, "failed to create descriptor set layout")

	return descriptor_set_layout
}

create_descriptor_pool :: proc(
	logical_device: vk.Device,
	descriptor_type: vk.DescriptorType,
	descriptor_count: u32,
) -> vk.DescriptorPool {
	pool_size := vk.DescriptorPoolSize {
		type            = descriptor_type,
		descriptorCount = descriptor_count,
	}

	pool_ci := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		poolSizeCount = 1,
		pPoolSizes    = &pool_size,
		maxSets       = descriptor_count,
	}

	descriptor_pool: vk.DescriptorPool
	descriptor_pool_result := vk.CreateDescriptorPool(
		logical_device,
		&pool_ci,
		nil,
		&descriptor_pool,
	)

	assert(descriptor_pool_result == .SUCCESS, "failed to create descriptor pool")

	return descriptor_pool
}

create_descriptor_set :: proc(
	logical_device: vk.Device,
	descriptor_pool: vk.DescriptorPool,
	descriptor_layout: vk.DescriptorSetLayout,
	descriptor_count: u32,
) -> []vk.DescriptorSet {
	descriptor_layouts := make([]vk.DescriptorSetLayout, descriptor_count)
	defer delete(descriptor_layouts)

	for i in 0 ..< descriptor_count {
		descriptor_layouts[i] = descriptor_layout
	}

	allocation_i := vk.DescriptorSetAllocateInfo {
		sType              = .DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = descriptor_pool,
		descriptorSetCount = descriptor_count,
		pSetLayouts        = raw_data(descriptor_layouts),
	}

	descriptor_sets := make([]vk.DescriptorSet, descriptor_count)
	descriptor_sets_result := vk.AllocateDescriptorSets(
		logical_device,
		&allocation_i,
		raw_data(descriptor_sets),
	)

	assert(descriptor_sets_result == .SUCCESS, "failed to allocate descriptor sets")

	return descriptor_sets
}

update_descriptor_set :: proc(
	logical_device: vk.Device,
	descriptor_set: vk.DescriptorSet,
	uniform_buffer: vk.Buffer,
) {
	buffer_i := vk.DescriptorBufferInfo {
		buffer = uniform_buffer,
		offset = 0,
		range  = size_of(Uniform_Buffer_Object),
	}

	write_descriptor_set := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = descriptor_set,
		dstBinding      = 0,
		dstArrayElement = 0,
		descriptorCount = 1,
		descriptorType  = .UNIFORM_BUFFER,
		pBufferInfo     = &buffer_i,
	}

	vk.UpdateDescriptorSets(logical_device, 1, &write_descriptor_set, 0, nil)
}


update_uniform_buffer :: proc(
	start_time: time.Tick,
	ubo_map_memory_ptr: rawptr,
	swap_chain_extent: vk.Extent2D,
) {
	elapsed_seconds := f32(time.tick_since(start_time)) / f32(time.Second)

	angle := elapsed_seconds * math.to_radians_f32(90)

	width := swap_chain_extent.width
	height := swap_chain_extent.height

	if height == 0 {
		return
	}

	aspect := f32(width) / f32(height)

	ubo := Uniform_Buffer_Object {
		model = linalg.matrix4_rotate(angle, vec3{0.0, 0.0, 1.0}),
		view  = linalg.matrix4_look_at(
			vec3{2.0, 2.0, 2.0},
			vec3{0.0, 0.0, 0.0},
			vec3{0.0, 0.0, 1.0},
		),
		proj  = linalg.matrix4_perspective(math.to_radians_f32(45.0), aspect, 0.1, 10.0),
	}

	ubo.proj[1, 1] *= -1
	mapped_ubo := cast(^Uniform_Buffer_Object)ubo_map_memory_ptr
	mapped_ubo^ = ubo
}

create_image :: proc(
	logical_device: vk.Device,
	physical_device: vk.PhysicalDevice,
	width: u32,
	height: u32,
	format: vk.Format,
	usage: vk.ImageUsageFlags,
	properties: vk.MemoryPropertyFlags,
) -> (
	vk.Image,
	vk.DeviceMemory,
) {
	image_ci := vk.ImageCreateInfo {
		sType = .IMAGE_CREATE_INFO,
		imageType = .D2,
		extent = {width = width, height = height, depth = 1},
		mipLevels = 1,
		arrayLayers = 1,
		format = format,
		tiling = .OPTIMAL,
		initialLayout = .UNDEFINED,
		usage = usage,
		sharingMode = .EXCLUSIVE,
		samples = {._1},
	}

	image: vk.Image
	image_result := vk.CreateImage(logical_device, &image_ci, nil, &image)
	assert(image_result == .SUCCESS, "failed to create image")

	memory_requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(logical_device, image, &memory_requirements)

	memory_type_index, ok := find_memory_type(
		physical_device,
		memory_requirements.memoryTypeBits,
		properties,
	)

	assert(ok, "failed to find memory type")

	allocation_i := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = memory_requirements.size,
		memoryTypeIndex = memory_type_index,
	}

	image_memory: vk.DeviceMemory
	image_memory_result := vk.AllocateMemory(logical_device, &allocation_i, nil, &image_memory)
	assert(image_memory_result == .SUCCESS, "failed to allocate image memory")

	image_bind_result := vk.BindImageMemory(logical_device, image, image_memory, vk.DeviceSize(0))
	assert(image_bind_result == .SUCCESS, "failed to bind image memory")

	return image, image_memory
}

create_image_texture :: proc(
	logical_device: vk.Device,
	physical_device: vk.PhysicalDevice,
	path: string,
	command_pool: vk.CommandPool,
	queue: vk.Queue,
) -> (
	vk.Image,
	vk.DeviceMemory,
) {
	image_source, err := image.load(path, {.alpha_add_if_missing})
	assert(err == nil, "failed to open image file")
	assert(image_source.channels == 4, "image shuld have 4 channels - rgba")

	width := u32(image_source.width)
	height := u32(image_source.height)
	size := u64(width) * u64(height) * u64(image_source.channels)

	staging_buffer, staging_buffer_memory := create_buffer(
		physical_device,
		logical_device,
		size,
		{.TRANSFER_SRC},
		{.HOST_VISIBLE, .HOST_COHERENT},
	)

	defer vk.DestroyBuffer(logical_device, staging_buffer, nil)
	defer vk.FreeMemory(logical_device, staging_buffer_memory, nil)

	memory_copy_to_buffer(
		logical_device,
		staging_buffer_memory,
		bytes.buffer_to_bytes(&image_source.pixels),
	)

	image.destroy(image_source)
	img, img_memory := create_image(
		logical_device,
		physical_device,
		width,
		height,
		.R8G8B8A8_SRGB,
		{.TRANSFER_DST, .SAMPLED},
		{.DEVICE_LOCAL},
	)

	command_buffer := begin_oneshot_commands(logical_device, command_pool)

	transition_image_layout(
		command_buffer,
		img,
		.UNDEFINED,
		.TRANSFER_DST_OPTIMAL,
		{},
		{.TRANSFER_WRITE},
		{.TOP_OF_PIPE},
		{.TRANSFER},
	)

	transfer_buffer_to_image(command_buffer, staging_buffer, img, width, height)

	transition_image_layout(
		command_buffer,
		img,
		.TRANSFER_DST_OPTIMAL,
		.SHADER_READ_ONLY_OPTIMAL,
		{.TRANSFER_WRITE},
		{.SHADER_READ},
		{.TRANSFER},
		{.FRAGMENT_SHADER},
	)

	end_oneshot_commands(logical_device, command_pool, command_buffer, queue)

	return img, img_memory
}

begin_oneshot_commands :: proc(
	logical_device: vk.Device,
	command_pool: vk.CommandPool,
) -> vk.CommandBuffer {
	command_buffer := create_command_buffer(logical_device, command_pool)
	begin_command_buffer(command_buffer, {.ONE_TIME_SUBMIT})
	return command_buffer
}

end_oneshot_commands :: proc(
	logical_device: vk.Device,
	command_pool: vk.CommandPool,
	command_buffer: vk.CommandBuffer,
	queue: vk.Queue,
) {
	command_buffer := command_buffer

	end_command_buffer(command_buffer)

	submit_i := vk.SubmitInfo {
		sType              = .SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &command_buffer,
	}

	submit_result := vk.QueueSubmit(queue, 1, &submit_i, 0)
	assert(submit_result == .SUCCESS, "failed to submit one shot command")

	wait_result := vk.QueueWaitIdle(queue)
	assert(wait_result == .SUCCESS, "failed to wait on queue completion")

	vk.FreeCommandBuffers(logical_device, command_pool, 1, &command_buffer)
}

create_sampler :: proc(
	logical_device: vk.Device,
	physical_device: vk.PhysicalDevice,
) -> vk.Sampler {
	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(physical_device, &properties)

	sampler_ci := vk.SamplerCreateInfo {
		sType                   = .SAMPLER_CREATE_INFO,
		magFilter               = .LINEAR,
		minFilter               = .LINEAR,
		addressModeU            = .REPEAT,
		addressModeV            = .REPEAT,
		addressModeW            = .REPEAT,
		anisotropyEnable        = true,
		maxAnisotropy           = properties.limits.maxSamplerAnisotropy,
		borderColor             = .INT_OPAQUE_BLACK,
		unnormalizedCoordinates = false,
		compareEnable           = false,
		compareOp               = .ALWAYS,
		mipmapMode              = .LINEAR,
		mipLodBias              = 0.0,
		minLod                  = 0.0,
		maxLod                  = 0.0,
	}

	sampler: vk.Sampler
	sampler_result := vk.CreateSampler(logical_device, &sampler_ci, nil, &sampler)


	return sampler
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

	ubo_descriptor_set_layout := create_descriptor_set_layout(logical_device)
	defer vk.DestroyDescriptorSetLayout(logical_device, ubo_descriptor_set_layout, nil)

	descriptor_pool := create_descriptor_pool(
		logical_device,
		.UNIFORM_BUFFER,
		VK_NUM_FRAMES_IN_FLIGHT,
	)
	defer vk.DestroyDescriptorPool(logical_device, descriptor_pool, nil)

	descriptor_sets := create_descriptor_set(
		logical_device,
		descriptor_pool,
		ubo_descriptor_set_layout,
		VK_NUM_FRAMES_IN_FLIGHT,
	)
	defer delete(descriptor_sets)

	graphics_pipeline, pipeline_layout := create_graphics_pipeline(
		logical_device,
		shader_module,
		"vertMain",
		"fragMain",
		swap_chain_format,
		ubo_descriptor_set_layout,
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

	vertices := []Vertex {
		{pos = {-0.5, -0.5}, color = {1.0, 0.0, 0.0}},
		{pos = {0.5, -0.5}, color = {0.0, 1.0, 0.0}},
		{pos = {0.5, 0.5}, color = {0.0, 0.0, 1.0}},
		{pos = {-0.5, 0.5}, color = {1.0, 1.0, 1.0}},
	}

	vertex_buffer, vertex_buffer_memory := create_buffer(
		physical_device,
		logical_device,
		u64(size_of(Vertex) * len(vertices)),
		{.VERTEX_BUFFER, .TRANSFER_DST},
		{.DEVICE_LOCAL},
	)

	transfer_to_buffer(physical_device, logical_device, graphics_queue, vertices, vertex_buffer)

	defer vk.DestroyBuffer(logical_device, vertex_buffer, nil)
	defer vk.FreeMemory(logical_device, vertex_buffer_memory, nil)

	fmt.println("Vulkan vertex buffer allocated and created")

	indices := []u16{0, 1, 2, 2, 3, 0}
	index_buffer, index_buffer_memory := create_buffer(
		physical_device,
		logical_device,
		u64(size_of(u16) * len(indices)),
		{.INDEX_BUFFER, .TRANSFER_DST},
		{.DEVICE_LOCAL},
	)

	transfer_to_buffer(physical_device, logical_device, graphics_queue, indices, index_buffer)

	defer vk.DestroyBuffer(logical_device, index_buffer, nil)
	defer vk.FreeMemory(logical_device, index_buffer_memory, nil)

	fmt.println("Vulkan index buffer allocated and created")

	img, img_memory := create_image_texture(
		logical_device,
		physical_device,
		"assets/images/statue.jpg",
		command_pool,
		graphics_queue,
	)

	defer vk.DestroyImage(logical_device, img, nil)
	defer vk.FreeMemory(logical_device, img_memory, nil)
	fmt.println("Vulkan image texture created")

	img_view := create_image_view(logical_device, img, .R8G8B8A8_SRGB)
	defer vk.DestroyImageView(logical_device, img_view, nil)
	fmt.println("Vulkan image view created")

	sampler := create_sampler(logical_device, physical_device)
	defer vk.DestroySampler(logical_device, sampler, nil)
	fmt.println("Vulkam sampler created")

	ubo_buffers: [VK_NUM_FRAMES_IN_FLIGHT]vk.Buffer
	ubo_buffer_memories: [VK_NUM_FRAMES_IN_FLIGHT]vk.DeviceMemory
	ubo_map_memory_ptrs: [VK_NUM_FRAMES_IN_FLIGHT]rawptr

	for i in 0 ..< VK_NUM_FRAMES_IN_FLIGHT {
		size := u64(size_of(Uniform_Buffer_Object))

		ubo_buffers[i], ubo_buffer_memories[i] = create_buffer(
			physical_device,
			logical_device,
			size,
			{.UNIFORM_BUFFER},
			{.HOST_VISIBLE, .HOST_COHERENT},
		)

		map_memory_result := vk.MapMemory(
			logical_device,
			ubo_buffer_memories[i],
			0,
			vk.DeviceSize(size),
			{},
			&ubo_map_memory_ptrs[i],
		)

		assert(map_memory_result == .SUCCESS, "failed to map ubo buffer memory")
	}
	defer for i in 0 ..< VK_NUM_FRAMES_IN_FLIGHT {
		vk.UnmapMemory(logical_device, ubo_buffer_memories[i])
		vk.DestroyBuffer(logical_device, ubo_buffers[i], nil)
		vk.FreeMemory(logical_device, ubo_buffer_memories[i], nil)
	}

	fmt.println("Vulkan uniform buffers created")

	for i in 0 ..< VK_NUM_FRAMES_IN_FLIGHT {
		update_descriptor_set(logical_device, descriptor_sets[i], ubo_buffers[i])
	}

	fmt.println("Vulkan descriptor sets updated")

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
	start_time := time.tick_now()

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
			update_uniform_buffer(start_time, ubo_map_memory_ptrs[frame_index], swap_chain_extent)

			reset_fence(logical_device, draw_fences[frame_index])

			record_command_buffer(
				command_buffers[frame_index],
				swap_chain_images[swap_chain_image_index],
				swap_chain_image_views[swap_chain_image_index],
				swap_chain_extent,
				graphics_pipeline,
				pipeline_layout,
				vertex_buffer,
				index_buffer,
				u32(len(indices)),
				descriptor_sets[frame_index],
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
