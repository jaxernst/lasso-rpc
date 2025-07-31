/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/livechain_web.ex",
    "../lib/livechain_web/**/*.*ex"
  ],
  theme: {
    extend: {},
  },
  plugins: [],
}