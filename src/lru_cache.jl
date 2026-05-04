mutable struct LRUCache{K}
	wkd::WeakKeyDict{K, Int}                        # key => heap handle
	heap::MutableBinaryMinHeap{Tuple{Int, WeakRef, Int}} # (counter, weakref(key), size_in_bytes)
	counter::Int
	total_size::Int # This is an upper bound for the size in bytes currently kept by the LRU cache
end

LRUCache{K}() where K = LRUCache{K}(WeakKeyDict{K, Int}(), MutableBinaryMinHeap{Tuple{Int,WeakRef,Int}}(), 0, 0)


function lru_touch!(f, lru::LRUCache{K}, key::K) where K
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
		sz = f()
		lru.total_size += sz
		push!(lru.heap, (lru.counter, WeakRef(key), sz))
	end
	if n_items == length(lru.heap)
		# No item was inserted, so we must update the prio of the old entry
		_, _, sz = lru.heap[handle]
		DataStructures.update!(lru.heap, handle, (lru.counter, WeakRef(key), sz))
	end

	lru
end

function lru_pop!(lru::LRUCache{K}) where {K}
	_,w,sz = pop!(lru.heap)
	lru.total_size -= sz
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

# Use Base.format_bytes(; binary=false) instead of inventing our own
# function _byte_size(n::Int)
# 	n < 1000   && return (n, " bytes")
# 	n < 1000^2 && return (round(n/1000,   digits=1), " kB")
# 	n < 1000^3 && return (round(n/1000^2, digits=1), " MB")
# 	              return (round(n/1000^3, digits=1), " GB")
# end
# _byte_size_string(n) = string(_byte_size(n)...)

function Base.show(io::IO, lru::LRUCache)
	print(io, "LRUCache($(length(lru)) items, ", Base.format_bytes(lru.total_size; binary=false), ")")
end
