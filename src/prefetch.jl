_prefetch(spec::Spec) = Spec(spec.ro, spec.use_cache, spec.forwarding_complete, true)
_prefetch(x) = x

prefetch(x::Any) = copy_nested(_prefetch, x)
