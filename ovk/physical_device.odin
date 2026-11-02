package ovk

import vk "vendor:vulkan"

Physical_Device :: struct {
    handle:            vk.PhysicalDevice,

    properties:        vk.PhysicalDeviceProperties,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    features:          vk.PhysicalDeviceFeatures,
    features_11:       vk.PhysicalDeviceVulkan11Features,
    features_12:       vk.PhysicalDeviceVulkan12Features,
    features_13:       vk.PhysicalDeviceVulkan13Features,
    queue_families:    []vk.QueueFamilyProperties,
    extensions:        []vk.ExtensionProperties,

    queue_family:      [Queue_Role]Maybe(u32),
}
