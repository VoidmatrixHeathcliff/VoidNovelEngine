#version 330

// Input vertex attributes (from vertex shader)
in vec2 fragTexCoord;
in vec4 fragColor;

// Input uniform values
uniform sampler2D texture0;      // Screen texture (replaces screen_texture)
uniform vec2 iResolution;        // Screen resolution in pixels
uniform float TIME;              // Shader time

// Output fragment color
out vec4 finalColor;

vec2 curve(vec2 uv)
{
    uv = (uv - 0.5) * 2.0;
    uv *= 1.1;
    uv.x *= 1.0 + pow((abs(uv.y) / 5.0), 2.5);
    uv.y *= 1.0 + pow((abs(uv.x) / 4.0), 2.5);
    uv  = (uv / 2.0) + 0.5;
    uv =  uv * 0.92 + 0.04;
    return uv;
}

void main()
{
    vec2 q = fragTexCoord;
    vec2 uv = q;
    uv = curve(uv);
    
    vec3 oricol = texture(texture0, vec2(q.x, q.y)).xyz;
    vec3 col;
    
    float x = sin(0.3*TIME + uv.y*21.0) * 
              sin(0.7*TIME + uv.y*29.0) * 
              sin(0.3 + 0.33*TIME + uv.y*31.0) * 0.0017;

    col.r = texture(texture0, vec2(x + uv.x + 0.001, uv.y + 0.001)).x + 0.05;
    col.g = texture(texture0, vec2(x + uv.x + 0.000, uv.y - 0.002)).y + 0.05;
    col.b = texture(texture0, vec2(x + uv.x - 0.002, uv.y + 0.000)).z + 0.05;
    
    col.r += 0.08 * texture(texture0, 0.35*vec2(x + 0.025, -0.027) + vec2(uv.x + 0.001, uv.y + 0.001)).x;
    col.g += 0.05 * texture(texture0, 0.35*vec2(x - 0.022, -0.02) + vec2(uv.x + 0.000, uv.y - 0.002)).y;
    col.b += 0.08 * texture(texture0, 0.35*vec2(x - 0.02, -0.018) + vec2(uv.x - 0.002, uv.y + 0.000)).z;

    col = clamp(col * 0.6 + 0.4 * col * col * 1.0, 0.0, 1.0);

    float vig = (0.0 + 1.0 * 16.0 * uv.x * uv.y * (1.0 - uv.x) * (1.0 - uv.y));
    col *= vec3(pow(vig, 0.3));

    col *= vec3(0.95, 1.05, 0.95);
    col *= 2.8;

    float scans = clamp(0.35 + 0.35 * sin(3.5 * TIME + uv.y * iResolution.y * 1.5), 0.0, 1.0);
    float s = pow(scans, 1.7);
    col = col * vec3(0.4 + 0.7 * s);

    col *= 1.0 + 0.01 * sin(110.0 * TIME);
    
    if (uv.x < 0.0 || uv.x > 1.0) col *= 0.0;
    if (uv.y < 0.0 || uv.y > 1.0) col *= 0.0;
    
    // Create scanline effect
    float scanline = clamp((mod(gl_FragCoord.x, 2.0) - 1.0) * 2.0, 0.0, 1.0);
    col *= 1.0 - 0.65 * vec3(scanline);

    finalColor = vec4(col, 1.0);
}