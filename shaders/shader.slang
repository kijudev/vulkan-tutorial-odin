// >---------------------------------------------------------------------- types

struct VertexInput
{
    float2 pos;
    float3 color;
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
};

// >-------------------------------------------------------------------- buffers

ConstantBuffer<UniformBuffer> ubo;

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
    return output;
}

// >------------------------------------------------------------ fragment shader

[shader("fragment")]
float4 fragMain(VertexOutput input) : SV_Target
{
    return float4(input.color, 1.0);
}
