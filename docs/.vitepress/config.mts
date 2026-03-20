import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'GoodPipeline',
  description: 'DAG-based job pipeline orchestration for Rails, built on GoodJob.',
  base: '/good_pipeline/',

  themeConfig: {
    nav: [
      { text: 'Home', link: '/' },
      { text: 'Docs', link: '/introduction' },
    ],

    sidebar: [
      {
        text: 'Getting Started',
        items: [
          { text: 'Introduction', link: '/introduction' },
          { text: 'Installation & Setup', link: '/getting-started' },
        ],
      },
      {
        text: 'Core Guides',
        items: [
          { text: 'Defining Pipelines', link: '/defining-pipelines' },
          { text: 'DAG Validation', link: '/dag-validation' },
          { text: 'Failure Strategies', link: '/failure-strategies' },
          { text: 'Pipeline Chaining', link: '/pipeline-chaining' },
          { text: 'Lifecycle Callbacks', link: '/callbacks' },
        ],
      },
      {
        text: 'Operations',
        items: [
          { text: 'Monitoring & Introspection', link: '/monitoring' },
          { text: 'Web Dashboard', link: '/dashboard' },
          { text: 'Cleanup', link: '/cleanup' },
        ],
      },
      {
        text: 'Reference',
        items: [
          { text: 'Architecture', link: '/architecture' },
        ],
      },
    ],

    socialLinks: [
      { icon: 'github', link: 'https://github.com/milkstrawai/good_pipeline' },
    ],

    editLink: {
      pattern: 'https://github.com/milkstrawai/good_pipeline/edit/main/docs/:path',
      text: 'Edit this page on GitHub',
    },

    search: {
      provider: 'local',
    },

    footer: {
      message: 'Released under the MIT License.',
      copyright: 'Copyright 2026 MilkStraw AI',
    },
  },
})
