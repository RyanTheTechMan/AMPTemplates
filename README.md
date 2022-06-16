# AMPTemplates
A repository holding my templates for CubeCoders AMP.

## How to add these Templates to your AMP Installation
1. Go to the ADS Panel
2. Press **Configuration**
3. Press **Instance Deployment**
4. Click **Add** under **Configuration Repositories**
5. Type `RyanTheTechMan/AMPTemplates`
6. Press **OK**
7. Press **Fetch Latest** and wait for it to download the templetes

The downloaded templetes should now appear when you create an instance.


# Instance Notes

### BeamMP (BeamNG)
As of BeamMP Server **v3.0.0** to **v3.0.1**, the configuration file is [not generated correctly](https://github.com/BeamMP/BeamMP-Server/issues/105) on a fresh install.

The best way to fix this, at the moment, is by [manually downloading](https://github.com/BeamMP/BeamMP-Server/releases/tag/v2.3.3) **v2.3.3**, running it, then updating to the latest version.

#### BeamMP - Installation
1. [Add this repository to your AMP Configuration](https://github.com/RyanTheTechMan/AMPTemplates#how-to-add-these-templates-to-your-amp-installation)
2. Click **Create Instance**
3. Select **BeamMP**
4. Click Create Instance
5. If desired, edit the ports. Note that HTTP is disabled by default so it may not be used.
6. Open the Instance
7. Go to **Server Settings** and add your [AuthKey](https://beammp.com/k/dashboard) and edit any other settings here.

NOTE: If you would like the server to be visible on the server list be sure to disable Private.