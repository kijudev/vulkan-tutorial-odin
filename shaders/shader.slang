struct VertexInput
{
    float2 pos;
    float3 color;
};

struct VertexOutput
{
    float4 pos: SV_Position;
    float3 color;
};

[shader("vertex")]
VertexOutput vertMain(VertexInput input, uint id : SV_VertexID)
{
    VertexOutput output;

    output.pos = float4(input.pos, 0.0, 1.0);
    output.color = input.color;

    return output;
}

[shader("fragment")]
float4 fragMain(VertexOutput input) : SV_Target
{
    return float4(input.color, 1.0);
}
