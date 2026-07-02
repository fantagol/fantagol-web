type KitPreviewProps = {
  primary?: string;
  secondary?: string;
  third?: string;
  template?: string;
  logoMode?: string;
  crestPosition?: string;
  starsCount?: number;
};

export default function KitPreview({
  primary = "#FFFFFF",
  secondary = "#111417",
  third = "#A6E824",
  template = "default",
  logoMode = "center_horizontal",
  crestPosition = "left_chest",
  starsCount = 0,
}: KitPreviewProps) {
  const stars = "★".repeat(Math.min(starsCount, 5));

  return (
    <svg viewBox="0 0 260 320" className="mx-auto h-72 w-56">
      <path
        d="M75 40 L105 20 H155 L185 40 L225 75 L195 115 V285 H65 V115 L35 75 Z"
        fill={primary}
        stroke={secondary}
        strokeWidth="8"
        strokeLinejoin="round"
      />

      {template === "vertical_stripes" && (
        <>
          <rect x="95" y="38" width="25" height="240" fill={secondary} opacity="0.9" />
          <rect x="140" y="38" width="25" height="240" fill={secondary} opacity="0.9" />
        </>
      )}

      {template === "diagonal" && (
        <path d="M55 265 L205 55 L225 80 L80 285 Z" fill={secondary} opacity="0.9" />
      )}

      {template === "center_band" && (
        <rect x="110" y="35" width="40" height="250" fill={secondary} opacity="0.9" />
      )}

      <path d="M105 20 H155 L145 50 H115 Z" fill={third} opacity="0.95" />

      {stars && (
        <text
          x="130"
          y="76"
          textAnchor="middle"
          fontSize="18"
          fontWeight="900"
          fill={third}
        >
          {stars}
        </text>
      )}

      {logoMode === "center_horizontal" && (
        <>
          <text
            x="130"
            y="155"
            textAnchor="middle"
            fontSize="26"
            fontWeight="900"
            fill={secondary}
          >
            FantaGol
          </text>
          <text
            x="130"
            y="178"
            textAnchor="middle"
            fontSize="12"
            fontWeight="700"
            fill={secondary}
            opacity="0.75"
          >
            OFFICIAL KIT
          </text>
        </>
      )}

      {logoMode !== "center_horizontal" && (
        <g transform={crestPosition === "right_chest" ? "translate(165 95)" : "translate(68 95)"}>
          <path
            d="M22 0 L44 10 V34 C44 50 32 62 22 68 C12 62 0 50 0 34 V10 Z"
            fill={third}
            stroke={secondary}
            strokeWidth="3"
          />
          <text
            x="22"
            y="38"
            textAnchor="middle"
            fontSize="17"
            fontWeight="900"
            fill={secondary}
          >
            FG
          </text>
        </g>
      )}

      <path d="M65 285 H195 V305 H65 Z" fill={secondary} />
    </svg>
  );
}