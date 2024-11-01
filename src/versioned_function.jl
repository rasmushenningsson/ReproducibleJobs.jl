struct VersionedFunction{F}
	f::F
	v::VersionNumber
end

# Base.show(io::IO, vf::VersionedFunction) = print(io, vf.f, "@", vf.v)
Base.show(io::IO, vf::VersionedFunction) = print(io, vf.f)
