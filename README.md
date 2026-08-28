# AMPTemplates
A repository holding my templates for CubeCoders AMP.

## How to add these Templates to your AMP Installation
1. Go to the ADS Panel
2. Press **Configuration**
3. Press **Instance Deployment**
4. Click **Add** under **Configuration Repositories**
5. Type `RyanTheTechMan/AMPTemplates`
6. Press **OK**
7. Press **Fetch Latest** and wait for it to download the templates
8. Refresh your webpage

The downloaded templates should now appear when you create an instance.

# Instance Notes

### AzerothCore
This repository includes an AMP Generic Module template for [AzerothCore](https://www.azerothcore.org/) Wrath of the Lich King 3.3.5a servers.

The template is designed to run inside AMP's primary Debian Docker/container environment and supports both normal AzerothCore and the compatible [mod-playerbots](https://github.com/mod-playerbots/mod-playerbots) core/module combinations. Template v19 also manages supported long-running module companion services inside the same AMP container, beginning with the Python bridge for [Hokken/mod-llm-chatter](https://github.com/Hokken/mod-llm-chatter).

The first **Update** performs the source download, MySQL setup, compilation, and client-data setup, so it is more involved than a typical prebuilt game server installation.

See the **[AzerothCore AMP Install Guide](AZEROTHCORE.md)** for installation, networking, client setup, Playerbots, modules, updates, and troubleshooting.
