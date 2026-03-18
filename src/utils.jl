# Is this the canonical way to ensure we make the check at compile-time?
@generated function _keys_are_sorted(nt::NamedTuple)
    return :($(issorted(fieldnames(nt))))
end
function sort_namedtuple_by_keys(nt::T) where T<:NamedTuple
	if _keys_are_sorted(nt)
		nt
	else
		NamedTuple{TupleTools.sort(keys(nt))}(nt)
	end
end
