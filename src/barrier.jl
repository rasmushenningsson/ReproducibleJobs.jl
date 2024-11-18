struct Barrier
	spec::Spec
end

barrier(b::Barrier) = b
barrier(spec::Spec) = Barrier(spec)
barrier(x) = x # only applicable for Specs

Base.:(==)(a::Barrier, b::Barrier) = a.spec == b.spec
preprocess(b::Barrier) = b
deduplicate!(dedup::Deduplicator, b::Barrier) = Barrier(dedup(b.spec))
