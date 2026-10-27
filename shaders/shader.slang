// >---------------------------------------------------------------------- types

struct VertexInput
{
    float2 pos;
    float3 color;
    float2 tex_coord;
};

struct UniformBuffer {
    float4x4 model;
    float4x4 view;
    float4x4 proj;
};

struct VertexOutput
{
    float4 pos: SV_Position;
    float3 color;
    float2 tex_coord;
};

ConstantBuffer<UniformBuffer> ubo;
Sampler2D texture;

// >-------------------------------------------------------------- vertex shader


[shader("vertex")]
VertexOutput vertMain(VertexInput input, uint id : SV_VertexID)
{
    VertexOutput output;

    output.pos = mul(
        ubo.proj,
        mul(ubo.view, mul(ubo.model, float4(input.pos, 0.0, 1.0)))
    );

    output.color = input.color;
    output.tex_coord = input.tex_coord;
    
    return output;
}

// >------------------------------------------------------------ fragment shader

[shader("fragment")]
float4 fragMain(VertexOutput input) : SV_Target
{
    return texture.Sample(input.tex_coord);
}
