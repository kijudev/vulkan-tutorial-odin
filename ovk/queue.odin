package ovk

import vk "vendor:vulkan"

Queue_Role :: enum {
	Graphics,
	Compute,
	Transfer,
	Present,
}

Queue_Role_Bitset :: bit_set[Queue_Role]

Queue :: struct {
	handle: vk.Queue,
	family: u32,
	index:  u32,
	roles:  Queue_Role_Bitset,
}
