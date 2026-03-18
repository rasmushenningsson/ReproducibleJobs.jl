mutable struct LRUCache{K}
	wkd::WeakKeyDict{K, Int}                        # key => heap handle
	heap::MutableBinaryMinHeap{Tuple{Int, WeakRef}} # (counter, weakref(key))
	counter::Int
end

LRUCache{K}() where K = LRUCache{K}(WeakKeyDict{K, Int}(), MutableBinaryMinHeap{Tuple{Int,WeakRef}}(), 0)

function lru_touch!(lru::LRUCache{K}, key::K) where K
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
	handle = get!(lru.wkd, key) do
		push!(lru.heap, (lru.counter, WeakRef(key)))
	end
	if n_items == length(lru.heap)
		# No item was inserted, so we must update the prio of the old entry
		DataStructures.update!(lru.heap, handle, (lru.counter, WeakRef(key)))
	end

	lru
end

function lru_pop!(lru::LRUCache{K}) where {K}
	_,w = pop!(lru.heap)
	key = w.value
	key === nothing && return nothing
	key::K
	pop!(lru.wkd, key)
	return key
end

Base.length(lru::LRUCache) = length(lru.heap)
Base.isempty(lru::LRUCache) = isempty(lru.heap)

# We don't use Base.empty! for this, because typically you want to process items as they are removed.
# And this doesn't do that.
function force_empty!(lru::LRUCache)
	empty!(lru.wkd)
	empty!(lru.heap)
	lru.counter = 0
	lru
end
