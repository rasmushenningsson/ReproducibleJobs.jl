struct ReproducibleHashContext{T}
	parent::T
end
ReproducibleHashContext() = ReproducibleHashContext(HashVersion{4}())

StableHashTraits.parent_context(x::ReproducibleHashContext) = x.parent

# These are needed to ensure Fix1, Fix2 and ComposedFunction hash correctly, without them e.g. <(2) and >(2) would hash the same!
function StableHashTraits.transform_type(::Type{<:Base.Fix1{F,V}}, ::ReproducibleHashContext) where {F,V}
	"Base.Fix1", F, V
end
function StableHashTraits.transform_type(::Type{<:Base.Fix2{F,V}}, ::ReproducibleHashContext) where {F,V}
	"Base.Fix2", F, V
end
function StableHashTraits.transform_type(::Type{<:Base.ComposedFunction{F1,F2}}, ::ReproducibleHashContext) where {F1,F2}
	"Base.ComposedFunction", F1, F2
end
