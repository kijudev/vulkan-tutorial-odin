package main

import "core:fmt"
import "core:os"
import "vendor:glfw"
import vk "vendor:vulkan"

main :: proc() {
	fmt.println("---- Vulkan Tutorial Odin ----")

	if !glfw.Init() {
		fmt.eprintln("GLFW: failed to initialize")
	} else {
		fmt.println("GLFW: initialized")
	}

	vk.load_proc_addresses(rawptr(glfw.GetInstanceProcAddress))

	application_i := vk.ApplicationInfo {
		sType              = .APPLICATION_INFO,
		pApplicationName   = "vulkan-tutorial-odin",
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		pEngineName        = "farfocel",
		engineVersion      = vk.MAKE_VERSION(1, 0, 0),
		apiVersion         = vk.API_VERSION_1_0,
	}

	instance_ci := vk.InstanceCreateInfo {
		sType             = .INSTANCE_CREATE_INFO,
		pApplicationInfo  = &application_i,
		enabledLayerCount = 0,
	}

	instance: vk.Instance
	result := vk.CreateInstance(&instance_ci, nil, &instance)
	if result != vk.Result.SUCCESS {
		fmt.eprintln("VK: failed to create vulkan instance")
		os.exit(1)
	} else {
		vk.load_proc_addresses_instance(instance)
		fmt.println("VK: instance ok")
	}

	vk_sdk_path, found := os.lookup_env("VULKAN_SDK", context.allocator)
	defer delete(vk_sdk_path)

	if !found || vk_sdk_path == "" {
		fmt.eprintln("VK: VULKAN_SDK env variable is not set")
		os.exit(1)
	} else {
		fmt.println("VK: sdk path ok")
	}

	if !vk_check_validation_layer_support() {
		fmt.eprintln("VK: validation layers are not available")
		os.exit(1)
	} else {
		fmt.println("VK: validation layers ok")
	}

	slangc_name := "slangc"
	slangc_path := fmt.tprintf("%s/bin/%s", vk_sdk_path, slangc_name)
	if !os.exists(slangc_path) {
		fmt.eprintln("VK: slangc not found")
		os.exit(1)
	} else {
		fmt.println("VK: slangc ok")
	}

	fmt.println("SETUP: ok")
}

vk_check_validation_layer_support :: proc() -> b32 {
	layer_count: u32
	vk.EnumerateInstanceLayerProperties(&layer_count, nil)

	layers := make([]vk.LayerProperties, layer_count)
	defer delete(layers)

	vk.EnumerateInstanceLayerProperties(&layer_count, raw_data(layers))
	for &layer in layers {
		if cstring(&layer.layerName[0]) == "VK_LAYER_KHRONOS_validation" {
			return true
		}
	}

	return false
}
