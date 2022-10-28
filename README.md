# balenaVirt
Easily run virtual machines on balenaOS with native performance, powered by QEMU and KVM. Guests can even run balenaOS on balenaOS, allowing multiple containerized applications to run concurrently on one physical device.

Additionally, this allows balenaOS guests can take advantage of QEMU features such as shared backing images and disk [snapshots](https://wiki.qemu.org/Documentation/CreateSnapshot) via qcow2 images, rolling back to a previous snapshot, temporary snapshots, [pause and resume](https://qemu-project.gitlab.io/qemu/system/images.html#vm-005fsnapshots), and [live migration](https://developers.redhat.com/blog/2015/03/24/live-migrating-qemu-kvm-virtual-machines) to another host.

# Caveats

Because instances are virtualized, applications on separate guests must communicate between each other over the network, rather than using UNIX domain sockets or shared memory. Hardware access will typically require an IOMMU and VFIO passthrough to work, which is traditionally only supported on PCs. Your mileage may vary. This approach is most useful for running multiple services on the same physical machine, which don't require anything more than network access.

## Installation and Usage

### BalenaOS
Deploy with `balena push`

Grab a balenaOS image for your guest(s) using the dashboard, or CLI:
```
$ balena os download genericx86-64-ext -o rootfs.img
```

Images and configs can be copied to the named data volume for the application using SCP, assuming you have SSH access:
```
$ scp -P 22222 rootfs.img root@mydevice.local:/var/lib/docker/volumes/${appid}_resin-data/_data/
```

The config can be edited on your device from the dashboard inside the `main` container, or using SSH:
```
$ balena ssh mydevice.local main
~ # vi /data/guests.yml
```

This disk image would then be available inside the container at `/data/rootfs.img`.

### Development
Install dependencies using `npm i`, then run with `node cli.js`

Additional dependencies are QEMU, and optionally OVMF/AAVMF firmware for UEFI support.

## Configuration

Guests are defined using a `guests.yml` YAML config.  By default, the application looks for this file in the current directory, but the path can be specified as the environment variable `GUEST_CONFIG_PATH`. The `templates` array specifies machine configuration templates that can be used to launch fleets. Template variables correlate directly to QEMU command line arguments for the most part, with few exceptions. Notably, the `append` array can be used to add arguments to the command line directly.

Variable substitution is also supported in templates, using double curly brace (`{{var}}`) syntax. For example, the `guestId` variable can be substituted in strings, to identify machine specific resources, such as disk images, and logs.

The `guests` array specifies which templates to use, and how many instances to launch per template.

See the `examples/` directory for details.

### Template Variables
| Variable       | Description                                             |
| -------------- | ------------------------------------------------------- |
| `guestId`      | Unique numeric identifier for each guest within a fleet |
| `macAddress`   | Unique generated MAC for each guest                     |
| `templateName` | Name of the template used to create the fleet           |

### Disks
As mentioned above, templates support variable substitution for identifying resources that aren't shared between machines. For example, a a disk can be specified like so:
```yaml
drive:
  - if: virtio
    format: raw
    file: /data/guest{{guestId}}.img
    index: 0
    media: disk
```

A fleet of five devices would then require `guest0.img` through `guest4.img` to be present.

It should be noted that raw images lack many features of other image formats, such as qcow2. We can use a qcow2 image as a backing store, and have our instances write to copy-on-write (CoW) snapshots to save disk space.

A raw image can be converted to qcow2 like so:
`qemu-img convert -f raw -O qcow2 rootfs.img rootfs.qcow2`

After converting our raw image to qcow2, we can create additional CoW snapshot images using the original as a backing store:

```bash
$ for i in {0..4}; do \
qemu-img create -f qcow2 -F qcow2 -b rootfs.qcow2 guest${i}.qcow2 32G; \
done;
```

These CoW snapshots can now be used directly by guests:
```yaml
drive:
  - if: virtio
    format: qcow2
    file: /data/guest{{guestId}}.qcow2
    index: 0
    media: disk
```

If you want to resize an image after it's created, you can do this from the host OS CLI as well. Make sure to power off the guest before attempting to resize the disk:
```
$ balena run -it -v ${appid}_resin-data:/mnt alpine \
  apk add --update qemu-img \
  && qemu-img resize /mnt/guest0.qcow2 64G
```

## Networking
### Shared physical device

Check your network before you wreck your network:

Find the ethernet name for example something like this eno1 or enp89s0 
`` 
$ ip a
``

First, create a bridge on thee ethernet port preferably(wifi will require lan and dhcp server), and assign the physical interface as a slave. This can be done on the host OS using nmcli:

```
$ nmcli connection add type bridge ifname qemu0
$ nmcli connection add type bridge-slave ifname eno1 master qemu0
```

If you screw it up, then delete 
```
$ nmcli con show
$ nmcli con delete UUID
$ nmcli con add type bridge-slave ifname eno1 master qemu0
```

If you need to add back in ethernet
```
$ nmcli con show
$ nmcli con delete UUID
$ nmcli con add type ethernet ifname eno1
```

The changes will take affect after rebooting. Upon reconnecting to the device, you should see the physical interface with no address, and the bridge will now have an address.
You should now be able to see the address in an arp -a scan.

You can connect your guest to the bridge using the following QEMU options:
```
-net nic,model=virtio -net bridge,br=qemu0
```

This is formatted in the template in the `guests.yaml` file like so:
```
net:
  - nic:
    model: virtio
  - bridge:
    br: qemu0
```

You may need to allow forwarding from this bridge:
```
$ iptables -I FORWARD -i qemu0 -j ACCEPT
$ iptables -I FORWARD -o qemu0 -j ACCEPT
```

## Tips and Tricks
### Get guest `cmdline` from MAC address
At times, you may want to act on a specific guest, such as resizing the disk image, or other management tasks. In order to do this, you need to get the command line used to launch that specific guest, to figure out what the variables from the template were populated with.

One way to do this is to get the MAC address of the guest, either from the dashboard or SSH, then grep `/proc` for that MAC.

From the host OS of the hypervisor:
```
$ cat $(grep -ir "${mac_address}" /proc/*/cmdline | head -1 | cut -d: -f1) | tr '\000' ' '
```
