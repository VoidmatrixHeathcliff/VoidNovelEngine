#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform vec2 iResolution;
uniform float TIME;
uniform float crtStrength; // 强度控制 (0.0 = 无效果, 1.0 = 全效果)

out vec4 finalColor;

vec2 curve(vec2 uv, float strength)
{
    // 当强度为0时返回原始UV
    if (strength < 0.01) return uv;
    
    uv = (uv - 0.5) * 2.0;
    uv *= mix(1.0, 1.1, strength); // 基于强度控制变形程度
    
    // 根据强度插值计算曲线效果
    float curveX = 1.0 + pow((abs(uv.y) / 5.0), 2.5) * strength;
    float curveY = 1.0 + pow((abs(uv.x) / 4.0), 2.5) * strength;
    
    uv.x *= mix(1.0, curveX, strength);
    uv.y *= mix(1.0, curveY, strength);
    
    uv = (uv / 2.0) + 0.5;
    return mix(uv, uv * 0.92 + 0.04, strength);
}

void main()
{
    vec2 q = fragTexCoord;
    vec2 uv = curve(q, crtStrength);
    
    vec3 oricol = texture(texture0, q).xyz;
    vec3 col;
    
    // 色差效果强度基于crtStrength
    float x = crtStrength * sin(0.3*TIME + uv.y*21.0) * 
               sin(0.7*TIME + uv.y*29.0) * 
               sin(0.3 + 0.33*TIME + uv.y*31.0) * 0.0017;
    
    // 基本色差
    col.r = texture(texture0, vec2(x + uv.x + 0.001, uv.y + 0.001)).x + 0.05;
    col.g = texture(texture0, vec2(x + uv.x + 0.000, uv.y - 0.002)).y + 0.05;
    col.b = texture(texture0, vec2(x + uv.x - 0.002, uv.y + 0.000)).z + 0.05;
    
    // 附加色差效果
    col.r += 0.08 * texture(texture0, 0.35*vec2(x + 0.025, -0.027) + vec2(uv.x + 0.001, uv.y + 0.001)).x * crtStrength;
    col.g += 0.05 * texture(texture0, 0.35*vec2(x - 0.022, -0.02) + vec2(uv.x + 0.000, uv.y - 0.002)).y * crtStrength;
    col.b += 0.08 * texture(texture0, 0.35*vec2(x - 0.02, -0.018) + vec2(uv.x - 0.002, uv.y + 0.000)).z * crtStrength;
    
    // 保留原始颜色以平滑过渡
    if (crtStrength < 1.0) {
        col = mix(oricol, col, crtStrength);
    }
    
    col = clamp(col * 0.6 + 0.4 * col * col * 1.0, 0.0, 1.0);
    
    // 暗角效果（基于强度）
    float vig = (0.0 + 1.0 * 16.0 * uv.x * uv.y * (1.0 - uv.x) * (1.0 - uv.y));
    col *= mix(vec3(1.0), vec3(pow(vig, 0.3)), crtStrength);
    
    // 颜色平衡
    col *= mix(vec3(1.0), vec3(0.95, 1.05, 0.95), crtStrength);
    
    // 整体亮度
    col *= mix(1.0, 2.8, crtStrength);
    
    // 扫描线效果（基于强度）
    float scans = clamp(0.35 + 0.35 * sin(3.5 * TIME + uv.y * iResolution.y * 1.5), 0.0, 1.0);
    float s = pow(scans, 1.7);
    col = col * mix(vec3(1.0), vec3(0.4 + 0.7 * s), crtStrength);
    
    // 高频闪烁（基于强度）
    col *= 1.0 + mix(0.0, 0.01, crtStrength) * sin(110.0 * TIME);
    
    // 边界裁剪
    if (uv.x < 0.0 || uv.x > 1.0) col *= 0.0;
    if (uv.y < 0.0 || uv.y > 1.0) col *= 0.0;
    
    // 扫描线效果（基于强度）
    float scanline = clamp((mod(gl_FragCoord.x, 2.0) - 1.0) * 2.0, 0.0, 1.0);
    col *= 1.0 - mix(0.0, 0.65, crtStrength) * vec3(scanline);
    
    // 平滑过度到原始图像
    if (crtStrength < 0.01) {
        col = oricol;
    }
    
    finalColor = vec4(col, 1.0);
}