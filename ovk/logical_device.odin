package ovk

import vk "vendor:vulkan"

Logical_Device :: struct {
    handle:      vk.Device,
    physical:    ^Physical_Device,
    queues:      [Queue_Role]Queue,
    features:    vk.PhysicalDeviceFeatures,
    features_11: vk.PhysicalDeviceVulkan11Features,
    features_12: vk.PhysicalDeviceVulkan12Features,
    features_13: vk.PhysicalDeviceVulkan13Features,
    extensions:  []cstring,
}
