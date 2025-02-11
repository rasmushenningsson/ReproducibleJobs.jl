struct VersionedFunction{F}
	f::F
	v::VersionNumber
end

deduplicate_type(::Deduplicator, ::Type{<:VersionedFunction}) = false

# Base.show(io::IO, vf::VersionedFunction) = print(io, vf.f, "@", vf.v)
Base.show(io::IO, vf::VersionedFunction) = print(io, vf.f)
