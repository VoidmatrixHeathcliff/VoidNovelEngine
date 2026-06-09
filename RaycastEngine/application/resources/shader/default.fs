#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec4 colDiffuse;

out vec4 finalColor;

void main()
{
    vec4 texel = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
    vec2 centered = fragTexCoord - vec2(0.5, 0.5);
    float distance_from_center = length(centered);
    float edge = smoothstep(0.28, 0.72, distance_from_center);
    float vignette = mix(1.0, 0.35, edge);
    finalColor = vec4(texel.rgb * vignette, texel.a);
}
