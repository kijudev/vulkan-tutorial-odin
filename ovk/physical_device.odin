package ovk

import "core:strings"
import vk "vendor:vulkan"

// >-------------------------------------------------------- Constants and Types

Physical_Device :: struct {
	handle:                  vk.PhysicalDevice,
	properties:              vk.PhysicalDeviceProperties,
	memory_properties:       vk.PhysicalDeviceMemoryProperties,
	features:                vk.PhysicalDeviceFeatures,
	features_11:             vk.PhysicalDeviceVulkan11Features,
	features_12:             vk.PhysicalDeviceVulkan12Features,
	features_13:             vk.PhysicalDeviceVulkan13Features,
	queue_family_properties: []vk.QueueFamilyProperties,
	queue_families:          [Queue_Role]u32,
	extensions:              []vk.ExtensionProperties,
}

Physical_Device_Params :: struct {
	extensions:  []string,
	features:    vk.PhysicalDeviceFeatures,
	features_11: vk.PhysicalDeviceVulkan11Features,
	features_12: vk.PhysicalDeviceVulkan12Features,
	features_13: vk.PhysicalDeviceVulkan13Features,
}

// >------------------------------------------------------------ Physical Device

physical_device_pick :: proc(
	pd: ^Physical_Device,
	instance: ^Instance,
	surface: vk.SurfaceKHR,
	params: ^Physical_Device_Params,
) -> bool {
	count: u32
	vk.EnumeratePhysicalDevices(instance.handle, &count, nil)
	handles := make([]vk.PhysicalDevice, count, context.temp_allocator)
	vk.EnumeratePhysicalDevices(instance.handle, &count, raw_data(handles))

	best_score := -1
	best: vk.PhysicalDevice

	for h in handles {
		candidate: Physical_Device
		query_properties(&candidate, h, context.temp_allocator)

		score := score(&candidate, surface, params)
		if score > best_score {
			best_score = score
			best = h
		}
	}

	if best_score < 0 do return false

	query_properties(pd, best, context.allocator)
	query_queue_families(pd, surface) or_return

	return true
}

physical_device_destroy :: proc(pd: Physical_Device, allocator := context.allocator) {
	delete(pd.queue_family_properties, allocator)
	delete(pd.extensions, allocator)
}

// >------------------------------------------------------------------ Internals

@(private = "file")
query_properties :: proc(
	pd: ^Physical_Device,
	handle: vk.PhysicalDevice,
	allocator := context.allocator,
) {
	pd.handle = handle

	// Query properties
	vk.GetPhysicalDeviceProperties(handle, &pd.properties)
	vk.GetPhysicalDeviceMemoryProperties(handle, &pd.memory_properties)

	// Query features
	pd.features_13 = {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		pNext = nil,
	}

	pd.features_12 = {
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext = &pd.features_13,
	}

	pd.features_11 = {
		sType = .PHYSICAL_DEVICE_VULKAN_1_1_FEATURES,
		pNext = &pd.features_12,
	}

	f2 := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &pd.features_11,
	}

	vk.GetPhysicalDeviceFeatures2(handle, &f2)
	pd.features = f2.features
	pd.features_11.pNext = nil
	pd.features_12.pNext = nil

	// Query queue families
	queue_family_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(handle, &queue_family_count, nil)
	pd.queue_family_properties = make([]vk.QueueFamilyProperties, queue_family_count)
	vk.GetPhysicalDeviceQueueFamilyProperties(
		handle,
		&queue_family_count,
		raw_data(pd.queue_family_properties),
	)

	// Query extensions
	extension_count: u32
	vk.EnumerateDeviceExtensionProperties(handle, nil, &extension_count, nil)
	pd.extensions = make([]vk.ExtensionProperties, extension_count)
	vk.EnumerateDeviceExtensionProperties(handle, nil, &extension_count, raw_data(pd.extensions))
}


@(private = "file")
check_params :: proc(pd: ^Physical_Device, params: ^Physical_Device_Params) -> bool {
	return check_extensions(pd, params.extensions) && check_features(pd, params)
}

@(private = "file")
query_queue_families :: proc(pd: ^Physical_Device, surface: vk.SurfaceKHR) -> (ok: bool) {
	NONE :: max(u32)
	families := [Queue_Role]u32 {
		.Graphics = NONE,
		.Compute  = NONE,
		.Transfer = NONE,
		.Present  = NONE,
	}

	for &family, idx in pd.queue_family_properties {
		idx := u32(idx)
		flags := family.queueFlags

		if .GRAPHICS in flags && families[.Graphics] == NONE do families[.Graphics] = idx
		if .COMPUTE in flags && .GRAPHICS not_in flags && families[.Compute] == NONE do families[.Compute] = idx

		if .TRANSFER in flags &&
		   .GRAPHICS not_in flags &&
		   .COMPUTE not_in flags &&
		   families[.Transfer] == NONE {
			families[.Transfer] = idx
		}

		present: b32
		vk.GetPhysicalDeviceSurfaceSupportKHR(pd.handle, idx, surface, &present)

		if present && (families[.Present] == NONE || idx == families[.Graphics]) do families[.Present] = idx
	}

	if families[.Graphics] == NONE || families[.Present] == NONE do return false
	if families[.Compute] == NONE do families[.Compute] = families[.Graphics]
	if families[.Transfer] == NONE do families[.Transfer] = families[.Compute]

	pd.queue_families = families
	return false
}


@(private = "file")
score :: proc(
	pd: ^Physical_Device,
	surface: vk.SurfaceKHR,
	params: ^Physical_Device_Params,
) -> int {
	if pd.properties.apiVersion < vk.API_VERSION_1_3 do return -1

	for ext in params.extensions do if !check_extension(pd, ext) do return -1
	if !check_features(pd, params) do return -1
	if ok := query_queue_families(pd, surface); !ok do return -1

	// the swapchain must have at least one format and present mode
	fmt_count, mode_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(pd.handle, surface, &fmt_count, nil)
	vk.GetPhysicalDeviceSurfacePresentModesKHR(pd.handle, surface, &mode_count, nil)

	if fmt_count == 0 || mode_count == 0 do return -1

	score := 0
	#partial switch pd.properties.deviceType {
	case .DISCRETE_GPU:
		score += 1000
	case .INTEGRATED_GPU:
		score += 100
	}

	return score
}

@(private = "file")
check_extension :: proc(pd: ^Physical_Device, required_extension: string) -> bool {
	for &extension in pd.extensions {
		if string(cstring(&extension.extensionName[0])) == required_extension {
			return true
		}
	}

	return false
}

@(private = "file")
check_extensions :: proc(pd: ^Physical_Device, required_extensions: []string) -> bool {
	for &required_extension in required_extensions {
		if !check_extension(pd, required_extension) {
			return false
		}
	}

	return true
}

@(private = "file")
as_b32s :: proc(p: ^$T, skip: int) -> []b32 {
	n := (size_of(T) - skip) / size_of(b32)
	return ([^]b32)(uintptr(p) + uintptr(skip))[:n]
}

@(private = "file")
check_features_subset :: proc(req: ^$T, have: ^T, skip: int) -> bool {
	r, h := as_b32s(req, skip), as_b32s(have, skip)

	for i in 0 ..< len(r) {
		if r[i] && !h[i] do return false
	}

	return true
}

@(private = "file")
check_features :: proc(pd: ^Physical_Device, params: ^Physical_Device_Params) -> bool {
	HEADER :: size_of(vk.BaseOutStructure)

	return(
		check_features_subset(&params.features, &pd.features, 0) &&
		check_features_subset(&params.features_11, &pd.features_11, HEADER) &&
		check_features_subset(&params.features_12, &pd.features_12, HEADER) &&
		check_features_subset(&params.features_13, &pd.features_13, HEADER) \
	)
}
