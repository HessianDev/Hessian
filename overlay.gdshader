shader_type canvas_item;

// The texture you want to overlay
uniform sampler2D overlay_texture : source_color;

// Opacity of the overlay (0 = transparent, 1 = fully opaque)
uniform float opacity : hint_range(0.0, 1.0) = 0.8;

// Tint color (multiplied with the texture)
uniform vec4 tint : source_color = vec4(1.0);

// Scale and offset to adjust the texture placement
uniform vec2 scale = vec2(1.0, 1.0);
uniform vec2 offset = vec2(0.0, 0.0);

// Blend mode: 0 = normal (alpha blend), 1 = additive, 2 = multiply
uniform int blend_mode : hint_range(0, 2) = 0;

void fragment() {
    // Sample the overlay texture with UV transformed by scale/offset
    vec2 uv = UV * scale + offset;
    vec4 tex_color = texture(overlay_texture, uv);

    // Apply tint and opacity
    tex_color *= tint;
    tex_color.a *= opacity;

    // Get the underlying panel's color (the ColorRect's own color, which we keep white)
    vec4 base_color = COLOR;  // COLOR is the modulate value of the ColorRect

    // Combine based on blend mode
    switch (blend_mode) {
        case 0: // Normal alpha blend
            COLOR = mix(base_color, tex_color, tex_color.a);
            break;
        case 1: // Additive
            COLOR = base_color + tex_color;
            break;
        case 2: // Multiply
            COLOR = base_color * tex_color;
            break;
        default:
            COLOR = tex_color;
    }

    // The final color is output; the panel underneath is untouched
}
}