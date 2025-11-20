/** @type {import('tailwindcss').Config} */
module.exports = {
  content: ["./js/**/*.js", "../lib/lasso_web.ex", "../lib/lasso_web/**/*.*ex"],
  theme: {
    extend: {
      animation: {
        "fade-in": "fadeIn 0.2s ease-out forwards",
        "fade-in-border": "fadeInBorder 0.3s ease-out forwards",
        "fade-in-up": "fadeInUp 0.5s ease-out forwards",
        float: "float 6s ease-in-out infinite",
        "pulse-glow": "pulseGlow 2s cubic-bezier(0.4, 0, 0.6, 1) infinite",
        shimmer: "shimmer 2s linear infinite",
      },
      keyframes: {
        fadeIn: {
          "0%": { opacity: "0" },
          "100%": { opacity: "1" },
        },
        fadeInBorder: {
          "0%": { borderColor: "transparent" },
          "100%": { borderColor: "rgb(55 65 81 / 0.5)" },
        },
        fadeInUp: {
          "0%": { opacity: "0", transform: "translateY(10px)" },
          "100%": { opacity: "1", transform: "translateY(0)" },
        },
        float: {
          "0%, 100%": { transform: "translateY(0)" },
          "50%": { transform: "translateY(-10px)" },
        },
        pulseGlow: {
          "0%, 100%": {
            opacity: "1",
            boxShadow: "0 0 0 0px rgba(168, 85, 247, 0.7)",
          },
          "50%": {
            opacity: "0.5",
            boxShadow: "0 0 0 10px rgba(168, 85, 247, 0)",
          },
        },
        shimmer: {
          "0%": { backgroundPosition: "-1000px 0" },
          "100%": { backgroundPosition: "1000px 0" },
        },
      },
    },
  },
  plugins: [],
};
