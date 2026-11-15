// ─────────────────────────────────────────────────────────────────────────────
// MagicCircle — 고리와 룬 문자가 서로 다른 속도로 도는 마법진 (URP, HLSL, 파티클/쿼드용)
//
//  텍스처 없이 UV 좌표의 수학만으로 그린다.
//  1) 극좌표   : UV 를 가운데 기준 (-1~1) 로 옮긴 뒤 반지름 r, 각도 angle 로 바꾼다
//  2) SDF 고리 : |r - 반지름| < 두께 이면 선. fwidth 로 화면 해상도에 맞춰 안티에일리어싱
//  3) 회전     : 바깥 층과 안쪽 층을 서로 반대 방향으로 회전 행렬로 돌린다
//  4) 룬 문자  : 각도를 RuneCount 칸으로 나누고, 칸 번호를 해시해 3x3 격자 획 조합으로 글자를 만든다
//  5) 별 다각형: 정N각형 SDF 두 개를 엇갈려 겹쳐 별 모양(N=3 이면 육망성)
//  6) 연출     : 맥동(pulse), 룬이 원을 따라 차례로 밝아지는 물결, 각도 진행값으로 그려지는 등장(Reveal)
//
//  * 가산 혼합(Blend One One)이라 겹칠수록 밝아지고, 파티클의 정점 색(Start Color, Color over Lifetime)이 곱해진다.
// ─────────────────────────────────────────────────────────────────────────────
Shader "MyShaders/MagicCircle"
{
    Properties
    {
        [Header(Color)]
        [HDR] _GlowColor ("Line Color", Color) = (0.5, 0.8, 3.0, 1)
        [HDR] _AccentColor ("Rune / Star Color", Color) = (2.2, 0.7, 2.8, 1)
        _Intensity ("Intensity", Range(0, 5)) = 1.5
        _HaloStrength ("Halo Strength", Range(0, 2)) = 0.6

        [Header(Shape)]
        _LineWidth ("Line Width", Range(0.002, 0.05)) = 0.012
        [IntRange] _RuneCount ("Rune Count", Range(6, 32)) = 16
        [IntRange] _TickCount ("Tick Count", Range(8, 128)) = 64
        [IntRange] _PolygonSides ("Star Polygon Sides", Range(3, 8)) = 3

        [Header(Motion)]
        _RotateSpeed ("Outer Rotate Speed", Float) = 0.25
        _InnerRotateSpeed ("Inner Rotate Speed", Float) = -0.5
        _PulseSpeed ("Pulse Speed", Float) = 2
        _PulseAmount ("Pulse Amount", Range(0, 1)) = 0.3
        _RuneWaveSpeed ("Rune Wave Speed", Float) = 3

        [Header(Reveal)]
        _Reveal ("Reveal (0 hidden - 1 full)", Range(0, 1)) = 1
    }

    SubShader
    {
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"
            "RenderType" = "Transparent"
            "Queue" = "Transparent"
            "IgnoreProjector" = "True"
            "PreviewType" = "Plane"
        }

        Pass
        {
            Name "MagicCircle"
            Tags { "LightMode" = "UniversalForward" }
            Blend One One      // 가산 혼합
            ZWrite Off
            Cull Off

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            CBUFFER_START(UnityPerMaterial)
                half4 _GlowColor;
                half4 _AccentColor;
                half  _Intensity;
                half  _HaloStrength;
                half  _LineWidth;
                float _RuneCount;
                float _TickCount;
                float _PolygonSides;
                float _RotateSpeed;
                float _InnerRotateSpeed;
                float _PulseSpeed;
                half  _PulseAmount;
                float _RuneWaveSpeed;
                half  _Reveal;
            CBUFFER_END

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv         : TEXCOORD0;
                half4  color      : COLOR;      // 파티클 정점 색
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv         : TEXCOORD0;
                half4  color      : COLOR;
            };

            Varyings Vert(Attributes v)
            {
                Varyings o;
                o.positionCS = TransformObjectToHClip(v.positionOS.xyz);
                o.uv    = v.uv;
                o.color = v.color;
                return o;
            }

            // ── 도구 함수 ───────────────────────────────────────────────────
            float Hash11(float n)
            {
                return frac(sin(n * 127.1) * 43758.5453);
            }

            float2 Rotate(float2 p, float a)
            {
                float s, c;
                sincos(a, s, c);
                return float2(c * p.x - s * p.y, s * p.x + c * p.y);
            }

            // 거리값 d 를 두께 w 의 매끈한 선으로 (aa = 픽셀 하나 크기)
            float LineMask(float d, float w, float aa)
            {
                return 1.0 - smoothstep(w, w + aa, d);
            }

            // 선분 a-b 까지의 거리
            float SdSegment(float2 p, float2 a, float2 b)
            {
                float2 pa = p - a;
                float2 ba = b - a;
                float  h  = saturate(dot(pa, ba) / dot(ba, ba));
                return length(pa - ba * h);
            }

            // 정N각형 테두리까지의 거리 (R = 꼭짓점까지 반지름)
            float SdPolygonEdge(float2 p, float n, float R)
            {
                float sector = TWO_PI / n;
                float a = atan2(p.y, p.x) + PI * 0.5;                 // 꼭짓점이 위를 향하도록
                a = abs(fmod(a + TWO_PI * 4.0, sector) - sector * 0.5); // 가장 가까운 변의 중심 기준 각도
                return abs(length(p) * cos(a) - R * cos(PI / n));
            }

            // 룬 글자 하나: 3x3 격자점 사이의 획 8개 중 일부를 칸 번호 해시로 켠다
            float RuneGlyph(float2 q, float id)
            {
                // q: 글자 칸 안의 좌표 (가운데 0, 범위 약 -0.5~0.5)
                const float s = 0.28;
                float d = SdSegment(q, float2(0, -s), float2(0, s));   // 가운데 세로획은 항상
                if (Hash11(id + 1.0) > 0.5) d = min(d, SdSegment(q, float2(-s,  s), float2( s,  s)));
                if (Hash11(id + 2.0) > 0.5) d = min(d, SdSegment(q, float2(-s, -s), float2( s, -s)));
                if (Hash11(id + 3.0) > 0.6) d = min(d, SdSegment(q, float2(-s,  0), float2( s,  0)));
                if (Hash11(id + 4.0) > 0.6) d = min(d, SdSegment(q, float2(-s, -s), float2(-s,  s)));
                if (Hash11(id + 5.0) > 0.6) d = min(d, SdSegment(q, float2( s, -s), float2( s,  s)));
                if (Hash11(id + 6.0) > 0.6) d = min(d, SdSegment(q, float2(-s, -s), float2( s,  s)));
                if (Hash11(id + 7.0) > 0.6) d = min(d, SdSegment(q, float2(-s,  s), float2( s, -s)));
                if (Hash11(id + 8.0) > 0.7) d = min(d, SdSegment(q, float2(0, s), float2(s, 0)));
                return d;
            }

            half4 Frag(Varyings i) : SV_Target
            {
                float  t  = _Time.y;
                float2 p  = i.uv * 2.0 - 1.0;          // 가운데가 (0,0), 가장자리가 ±1
                float  r  = length(p);
                float  aa = max(fwidth(r), 1e-4) * 1.5; // 화면에서 한 픽셀이 차지하는 거리
                float  w  = _LineWidth;

                // ── 바깥 층 (시계 반대 회전) ────────────────────────────────
                float2 pOuter  = Rotate(p, t * _RotateSpeed);
                float  angle01 = atan2(pOuter.y, pOuter.x) / TWO_PI + 0.5;   // 0~1

                float lines = 0.0;
                lines += LineMask(abs(r - 0.95), w,       aa);
                lines += LineMask(abs(r - 0.88), w * 0.6, aa);
                lines += LineMask(abs(r - 0.68), w,       aa);
                lines += LineMask(abs(r - 0.62), w * 0.6, aa);
                lines += LineMask(abs(r - 0.28), w * 0.8, aa);

                // 눈금: 0.88~0.95 사이, 각도를 TickCount 칸으로 나눈 칸 가운데에 짧은 선
                float tickCoord = angle01 * _TickCount;
                float tickAA    = max(fwidth(tickCoord), 1e-4);
                float tick      = LineMask(abs(frac(tickCoord) - 0.5), 0.08, tickAA * 1.5);
                tick *= step(0.89, r) * step(r, 0.94);
                lines += tick;

                // ── 룬 띠 (0.69~0.87) ─────────────────────────────────────
                float runeCoord = angle01 * _RuneCount;
                float runeId    = floor(runeCoord);
                float bandInner = 0.69;
                float bandOuter = 0.87;
                float radial    = (r - bandInner) / (bandOuter - bandInner);           // 띠 안에서 0~1
                float cellW     = TWO_PI * r / _RuneCount;                              // 칸의 실제 가로 길이
                float cellH     = bandOuter - bandInner;
                float2 q        = float2((frac(runeCoord) - 0.5) * cellW / cellH, radial - 0.5);
                float runeDist  = RuneGlyph(q, runeId) * cellH;                          // 실제 길이 단위로
                float rune      = LineMask(runeDist, w * 0.8, aa);
                rune *= step(0.0, radial) * step(radial, 1.0);
                // 룬이 원을 따라 하나씩 차례로 밝아지는 물결
                rune *= 0.45 + 0.55 * saturate(sin(t * _RuneWaveSpeed - runeId * 0.7) * 0.5 + 0.5);

                // ── 안쪽 층 (반대 방향 회전) : 엇갈린 정N각형 두 개 = 별 ─────────
                float2 pInner = Rotate(p, t * _InnerRotateSpeed);
                float  n      = _PolygonSides;
                float  star   = LineMask(SdPolygonEdge(pInner, n, 0.61), w, aa);
                star += LineMask(SdPolygonEdge(Rotate(pInner, PI / n), n, 0.61), w, aa);
                star *= step(r, 0.63);

                // 가운데 작은 원 위에 꼭짓점마다 점
                float2 pCore   = Rotate(p, -t * _InnerRotateSpeed * 2.0);
                float  dotsAng = atan2(pCore.y, pCore.x) / TWO_PI * (n * 2.0);
                float2 dotUV   = float2((frac(dotsAng) - 0.5) * TWO_PI * 0.28 / (n * 2.0), r - 0.28);
                float  dots    = LineMask(length(dotUV), w * 1.8, aa);

                // ── 빛무리(halo) ───────────────────────────────────────────
                float halo = exp(-pow((r - 0.93) * 14.0, 2.0))
                           + exp(-pow((r - 0.65) * 14.0, 2.0)) * 0.6
                           + saturate(1.0 - r) * 0.15;
                halo *= _HaloStrength * saturate((1.0 - r) / 0.06);   // 쿼드 가장자리(r=1)에서 0 → 네모나게 잘리지 않게

                // ── 등장 연출 & 맥동 ───────────────────────────────────────
                float rawAngle01 = frac(atan2(p.x, p.y) / TWO_PI + 1.0);   // 12시 = 0, 시계 방향으로 증가 → 12시부터 그려진다
                float reveal = 1.0 - smoothstep(_Reveal - 0.02, _Reveal, rawAngle01);
                reveal = (_Reveal >= 1.0) ? 1.0 : reveal;
                float pulse = 1.0 + _PulseAmount * sin(t * _PulseSpeed);

                half3 color = _GlowColor.rgb * (saturate(lines) + halo)
                            + _AccentColor.rgb * saturate(rune + star + dots);
                color *= _Intensity * pulse * reveal;
                color *= i.color.rgb * i.color.a;     // 파티클 색/수명에 따른 페이드

                return half4(color, 1.0);
            }
            ENDHLSL
        }
    }
    FallBack Off
}
