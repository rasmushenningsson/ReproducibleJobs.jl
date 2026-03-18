mutable struct LRUCache{K, V}
	wkd::WeakKeyDict{K, Tuple{V, Int}}              # key → (value, heap handle)
	heap::MutableBinaryMinHeap{Tuple{Int, WeakRef}} # (access time, weakref(key))
	counter::Int
end

LRUCache{K,V}() where {K,V} = LRUCache{K,V}(WeakKeyDict{K, Tuple{V,Int}}(), MutableBinaryMinHeap{Tuple{Int,WeakRef}}(), 0)

function lru_touch!(lru::LRUCache{K,V}, key::K, val::V) where {K,V}
	lru.counter += 1

	# if haskey(lru.wkd, key)
	# 	old_val, handle = lru.wkd[key]
	# 	@assert old_val === val # We are not allowed to change the value when updating
	# 	# lru.wkd[key] = (val, handle)
	# 	DataStructures.update!(lru.heap, handle, (lru.counter, WeakRef(key)))
	# else
	# 	handle = push!(lru.heap, (lru.counter, WeakRef(key)))
	# 	lru.wkd[key] = (val, handle)
	# end

	# Attempt to rewrite using `get!` in order to avoid one lookup.
	n_items = length(lru.heap)
	old_val, handle = get!(lru.wkd, key) do
		h = push!(lru.heap, (lru.counter, WeakRef(key)))
		val, h
	end
	if n_items == length(lru.heap)
		# No item was inserted, so we must update the prio of the old entry
		@assert old_val === val # We are not allowed to change the value when updating
		DataStructures.update!(lru.heap, handle, (lru.counter, WeakRef(key)))
	end

	lru
end

function lru_pop!(lru::LRUCache{K}) where {K}
	_, ref = pop!(lru.heap)
	key = ref.value
	key === nothing && return nothing
	key::K
	val, _ = pop!(lru.wkd, key)
	return key, val
end

Base.length(lru::LRUCache) = length(lru.heap)

function Base.empty!(lru::LRUCache)
	empty!(lru.wkd)
	empty!(lru.heap)
	lru
end
