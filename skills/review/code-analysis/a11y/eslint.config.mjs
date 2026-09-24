import jsxA11y from 'eslint-plugin-jsx-a11y';
import tsParser from '@typescript-eslint/parser';

// ponytail: the plugin's `recommended` set only — mechanical defects a parser can
// see (missing alt, unlabeled control, click-without-key-handler, bogus role).
// Focus management, contrast and reading order need judgment; a review agent's job.
// ponytail: one TS parser for .jsx too — it handles plain JSX, so no second block.
export default [
  {
    files: ['**/*.jsx', '**/*.tsx'],
    languageOptions: {parser: tsParser, parserOptions: {ecmaFeatures: {jsx: true}}},
    plugins: {'jsx-a11y': jsxA11y},
    rules: jsxA11y.flatConfigs.recommended.rules,
  },
];
