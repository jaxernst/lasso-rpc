/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/lasso_web.ex",
    "../lib/lasso_web/**/*.*ex"
  ],
  theme: {
    extend: {},
  },
  plugins: [],
}