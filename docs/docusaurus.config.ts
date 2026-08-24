import { themes as prismThemes } from 'prism-react-renderer';
import type { Config } from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

// This runs in Node.js - Don't use client-side code here (browser APIs, JSX...)

const serverUrl = process.env.DOCS_URL || 'https://localhost:8000';

const config: Config = {
    title: 'SECAP Server Docs',
    tagline: 'Documentation for the SECAP',
    favicon: 'img/secap.ico',

    // Future flags, see https://docusaurus.io/docs/api/docusaurus-config#future
    future: {
        v4: true, // Improve compatibility with the upcoming Docusaurus v4
    },

    // Set the production url of your site here
    url: 'https://localhost:8000',
    // Set the /<baseUrl>/ pathname under which your site is served
    // For GitHub pages deployment, it is often '/<projectName>/'
    baseUrl: '/docs/',

    // GitHub pages deployment config.
    // If you aren't using GitHub pages, you don't need these.
    organizationName: 'SECAP',
    projectName: 'SECAP', // Usually your repo name.

    onBrokenLinks: 'throw',

    // Even if you don't use internationalization, you can use this field to set
    // useful metadata like html lang. For example, if your site is Chinese, you
    // may want to replace "en" with "zh-Hans".
    i18n: {
        defaultLocale: 'en',
        locales: ['en', "ir"],
    },

    presets: [
        [
            'classic',
            {
                docs: {
                    sidebarPath: './sidebars.ts',
                    // Please change this to your repo.
                    // Remove this to remove the "edit this page" links.
                    editUrl:
                        'https://github.com/facebook/docusaurus/tree/main/packages/create-docusaurus/templates/shared/',
                },
                blog: {
                    showReadingTime: true,
                    feedOptions: {
                        type: ['rss', 'atom'],
                        xslt: true,
                    },
                    // Please change this to your repo.
                    // Remove this to remove the "edit this page" links.
                    editUrl:
                        'https://github.com/facebook/docusaurus/tree/main/packages/create-docusaurus/templates/shared/',
                    // Useful options to enforce blogging best practices
                    onInlineTags: 'warn',
                    onInlineAuthors: 'warn',
                    onUntruncatedBlogPosts: 'warn',
                },
                theme: {
                    customCss: './src/css/custom.css',
                },
            } satisfies Preset.Options,
        ],
    ],

    themeConfig: {
        // Replace with your project's social card
        image: 'img/docusaurus-social-card.jpg',
        colorMode: {
            respectPrefersColorScheme: true,
        },
        navbar: {
            style: "dark",
            title: 'SECAP Document',
            logo: {
                alt: 'SECAP Logo',
                src: 'img/secap-dark-logo.png',
            },
            items: [
                {
                    type: 'docSidebar',
                    sidebarId: 'tutorialSidebar',
                    position: 'left',
                    label: 'Tutorial',
                },
                // { to: '/blog', label: 'Blog', position: 'left' },
                { to: 'http://localhost:9000', label: 'Portainer', position: 'right' },
                { to: 'http://localhost:3000', label: 'Grafana', position: 'right' },
                { to: 'http://localhost:5555', label: 'Celery', position: 'right' },
                { to: 'http://localhost:8080', label: 'Repository', position: 'right' },
                {
                    href: 'https://github.com/aminkhani',
                    label: 'GitHub',
                    position: 'right',
                },
            ],
        },
        footer: {
            style: 'dark',
            links: [
                {
                    title: 'Docs',
                    items: [
                        {
                            label: 'Tutorial',
                            to: '/docs/intro',
                        },
                    ],
                },
                {
                    title: 'Follow Me',
                    items: [
                        {
                            label: 'Github',
                            href: 'https://github.com/aminkhani/',
                        },
                        {
                            label: 'Telegram',
                            href: 'https://t.me/aminkhani_ai',
                        },
                    ],
                },
            ],
            copyright: `Made with ❤️ by Aminkhani`,
        },
        prism: {
            theme: prismThemes.github,
            darkTheme: prismThemes.dracula,
        },
    } satisfies Preset.ThemeConfig,
};

export default config;
