# truenas-tailscale-https
HTTPS WebUI with Tailscale on TrueNAS SCALE

## Rationale
Fairly simple, on a TrueNAS SCALE machine with the official Tailscale container, I want to automatically provision and refresh TLS certificates to access the WebUI over HTTPS. While you can use self-signed certificates or manually copy Tailscale certificates, these are imperfect solutions for many reasons. Is this largely driven by wanting my password manager to autofill my password in the WebUI? Yes, yes it is. But, there doesn't seem to be any public scripts that do this so it still seemed useful.

## Guide
**Note:** This guide assumes you have already setup your Tailscale container with standard settings, and that your hostname and tailscale machine name matches

Copy the script to your home directory through SSH or the WebUI console interface using the command below:

```
wget https://raw.githubusercontent.com/kc3wny/truenas-tailscale-https/refs/heads/main/renew_tailscale_cert.sh && chmod +x renew_tailscale_cert.sh
```

Edit this script to include your `machine-name.tailnet-name.ts.net` address so the correct certificate can be provisoned

Test the script using the command below before moving on:

```
sudo pathtoscript/renew_tailscale_cert.sh
```

Check the output, if you see `Success! WebUI updated to use machine-name.tailnet-name.ts.net` then it has been sucessfully provisioned.

To automate this task, we will use a cron job. Go to System > Advanced Settings > Cron Jobs and add a new one, name it something memorable. Configure it as below:
- Command: `pathtoscript/renew_tailscale_cert.sh'
- Run As User: root
- Schedule: (0 0 1 * *) (note: this can be at any interval, but given Tailscale certs are only valid for 90 days, a monthly refresh is advisable)
- Enabled: Yes

You should manually run this in the WebUI, if you have email alerts configured you will recieve an error output if the script fails to run. Another way to check is to note the time on tailscale certificate name (last set of numbers), if it matches when you started the cron job that means it ran successfully.
