package main

import "core:encoding/uuid"
import "core:fmt"
import "core:os"

compile_slang_shader :: proc(slang_path: string, entry_points: []string) -> ([]byte, bool) {
	defer free_all(context.temp_allocator)

	vulkan_sdk_path, ok := os.lookup_env("VULKAN_SDK", context.temp_allocator)

	if !ok || vulkan_sdk_path == "" {
		return nil, false
	}

	slangc_executable := "clangc"
	slangc_path := fmt.tprintf("%s/bin/%s", vulkan_sdk_path, slangc_executable)

	id := uuid.generate_v4()
	id_string := uuid.to_string(id, context.temp_allocator)
	temp_dir, _ := os.temp_dir(context.temp_allocator)

	spv_path := fmt.tprintf("%s/shader_%s.spv", temp_dir, id_string)
	defer os.remove(spv_path)

	commands := make([dynamic]string, 0, 16, context.temp_allocator)

	append(&commands, slangc_path, slang_path)

	append(
		&commands,
		"-target",
		"spirv",
		"-profile",
		"spirv_1_4",
		"-emit-spirv-directly",
		"-fvk-use-entrypoint-name",
	)

	for entry_point in entry_points {
		append(&commands, "-entry", entry_point)
	}

	append(&commands, "-o", spv_path)

	desc := os.Process_Desc {
		command = commands[:],
	}

	state, stdout, stderr, err := os.process_exec(desc, context.temp_allocator)

	if err != nil {
		fmt.eprintfln("Failed to run slangc: %s", os.error_string(err))
		return nil, false
	}

	if state.exit_code != 0 {
		fmt.eprintfln("slangc failed (exit code %d) for '%s':", state.exit_code, slang_path)

		if len(stderr) > 0 {
			fmt.eprintln(string(stderr))
		}

		if len(stdout) > 0 {
			fmt.eprintln(string(stdout))
		}

		return nil, false
	}

	spv, read_err := os.read_entire_file_from_path(spv_path, context.temp_allocator)
	if read_err != nil {
		fmt.eprintfln(
			"Failed to read compiled SPIR-V '%s': %s",
			spv_path,
			os.error_string(read_err),
		)

		return nil, false
	}

	return spv, true
}
