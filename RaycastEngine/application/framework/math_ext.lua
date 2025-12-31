math.clamp = function(val, min, max)
    return math.min(math.max(val, min), max)
end

math.lerp = function(a, b, t)
    return a + (b - a) * t
end