# collector

Get environment data for my orchids

## Abstract

A way to test all possible tools around k8s.


## Architecture


```
                                                                                                                           
                                                                                                                           
                                                                                                                           
                                                                                                                           
                                                    ┌──────────┐        ┌──────────────────────────────────────────────┐   
                                                    │          │        │ Raspberry                                    │   
                                                    │          │        │                                              │   
       ┌───────────────────────────────────┐        │          │        │   ┌──────────────────────────────┐           │   
       │  Main                             │        │Broker    │        │   │  Edge                        │           │   
       │  Suse Rancher k8s                 │        │(mqtt,etc)│        │   │  k3s -k8s-                   │           │   
       │                                   │        │          │        │   │                              │           │   
       │                                   │        │          │        │   │                              │           │   
       │   ┌──────────┐      ┌─────────┐   │        │          │        │   │                              │           │   
       │   │ddbb      ┼─────►│UI (???) │   │        │          │        │   │  ┌────────────┐              │           │   
       │   │    ▲     │      │         │   │        │          │        │   │  │temp/buf ddbb              │           │   
       │   └────┼─────┘      └─────────┘   │        │          │        │   │  │            │              │           │   
       │   ┌────┼─────┐                    │        │          │        │   │  └─────▲──────┘              │           │   
       │   │          │                    │        │          │        │   │  ┌─────┼──────┐              │           │   
       │   │Go svc Collector               │        │          │◄───────┼───┼──┼            │              │           │   
       │   │          │◄───────────────────┼────────┼          │        │   │  │Rust collector             │           │   
       │   └──────────┘                    │        │          │        │   │  └────────────┘              │           │   
       │                                   │        │          │        │   │        ▲    ▲                │           │   
       └───────────────────────────────────┘        └──────────┘        │   └────────┼────┼────────────────┘           │   
                  ▲                                                     │            │    │                            │   
                  │                                                     │            │    │                            │   
                  │                                                     │            │    │                            │   
                  │                                                     └────────────┼────┼────────────────────────────┘   
                  │                                                      ▲           │    │                                
                  │                                                      │           │    │                                
       ┌──────────┼─────────────────┐                                    │           │    │                                
       │                            │                                    │           │    │                                
       │ github                     │                                    │ ┌─────────┴─┐  └─────┬───────────┐              
       │                            ┼────────────────────────────────────┘ │           │        │           │              
       │    - Repo                  │                                      │Temp Sensor│        │HumidSensor│              
       │    - CI                    │                                      │           │        │           │              
       │                            │                                      └───────────┘        └───────────┘              
       │                            │                                                                                      
       │                            │                                                                                      
       │                            │                                                                                      
       └────────────────────────────┘                                                                                      
                                                                                                                           

```


## Initial deployment

- k3sup seems to be easy that ansible to deploy remote cluster (and local)


```
                                                                                         
  ┌────────────────────────────────┐                  ┌─────────────────────────────┐    
  │                                │                  │  raspberry                  │    
  │ Laptop                         │                  │    - k3s                    │    
  │  - k3s                         │                  │                             │    
  │  - rancher dashboard           │                  │                             │    
  │                                │                  │                             │    
  │                                │                  │                             │    
  │                                │                  │                             │    
  │                                │                  │                             │    
  │                                │                  │                             │    
  │                                │                  │                             │    
  │                                │                  │                             │    
  │                                │                  └─────────────────────────────┘    
  └────────────────────────────────┘                                     ▲               
                    ▲                                                    │               
                    │                                                    │               
                    │                                                    │ k3sup         
                    │k3sup                                               │               
                    │                                                    │               
                    │                                                    │               
                    │                                                    │               
                    │                                                    │               
                    │                                                    │               
         ┌──────────┴──────────────┬─────────────────────────────────────┘               
         │                         │                                                     
         │  bootstap vm            │                                                     
         │                         │                                                     
         │                         │                                                     
         │                         │                                                     
         │                         │                                                     
         │                         │                                                     
         │                         │                                                     
         └─────────────────────────┘
```


## Components

### Edge Collector

A rust process to read from sensors and send to central service through a broker (mqtt)

- Actual collector
- Simulator
    - Based in a env variable run a local process that generate random sensor
        data and sends to service collector .


## Tooling


- Languages 
    - Golang , main for mostly everything.
    - Rust, target the edge for fast/ small footprint.
- k8s
    - k3s 
        - For edge
        - For main
        - It's powerful enough change if you need :
            - Security FIPS 140-2.
            - Large Scale.
            - Windows workers.
                - Then use RKE2 (Rancher next step engine ...)
    - Suse Rancher instead of Openshift for central k8s

- Deployment
    - gitops
    - helm
    - argocd
        - One central site in central k8s also controls edge k8s deployments.


## Folder layout


```
my-fleet-ops/
├── .gitignore               # Excludes .kubeconfig, .env, and local binary builds
├── bootstrap/               # ONE-TIME AUTOMATION
│   └── provision-fleet.sh   # Script: k3sup install + argocd cluster add
│
├── gitops/                  # THE "FACTORY" (ArgoCD Infrastructure)
│   ├── app-set-main.yaml    # Logic to deploy apps to the Main cluster
│   └── app-set-edge.yaml    # Logic to deploy apps to Edge clusters
│
├── apps-config/             # THE "ENVIRONMENT OVERLAYS"
│   ├── main-values.yaml     # Specific settings for Laptop/Main (e.g., replicaCount: 3)
│   └── edge-values.yaml     # Specific settings for Edge nodes (e.g., resources: low)
│
└── charts/                  # THE "BLUEPRINTS" (Standard Helm Layout)
    ├── golang-api/          # --- Golang Application ---
    │   ├── Chart.yaml       # App metadata
    │   ├── values.yaml      # Default values (e.g. port: 8080)
    │   └── templates/       # Kubernetes YAMLs (deployment, service)
    │
    ├── rust-collector/      # --- Rust Collector Application ---
    │   ├── Chart.yaml       
    │   ├── values.yaml      # Default values (e.g. interval: 5s)
    │   └── templates/       
    │       ├── _helpers.tpl # Reusable template logic
    │       ├── deployment.yaml
    │       └── configmap.yaml
    │
    └── mqtt-broker/         # --- Mosquitto Broker ---
        ├── Chart.yaml
        ├── values.yaml      # Default config (persistence: true)
        └── templates/
```



# keys

The `~/.ssh/collector` key has no `passphrase`.


# Lab

## bridge for libvirt

To allow VMs to have "real" IPs in your network (making K8s services easily reachable), use a Linux bridge.

> **⚠️ WiFi Note:** Bridging over WiFi is generally **not supported** by most WiFi drivers (it causes `NO-CARRIER` or `DOWN` status). If you are on WiFi, stay with the **NAT (virbr0)** setup. The `provision-fleet.sh` script includes a fix for the NAT firewall to ensure reachability.

### 1. Create a bridge on the Host (OpenSUSE/nmcli)

Only use this if you have a physical **Ethernet cable** plugged in.

```bash
# Check existing bridges
ip addr show type bridge

# Create bridge br0 (replace enp0s31f6 with your physical interface)
sudo nmcli con add type bridge ifname br0 con-name br0
sudo nmcli con add type bridge-slave ifname enp0s31f6 con-name br0-port master br0
sudo nmcli con up br0-port
sudo nmcli con up br0
```

### 1.1 Delete the bridge

```bash
sudo nmcli con delete br0
sudo nmcli con delete br0-port
```

### 2. Define bridge in libvirt

Create `bridge.xml`:
```xml
<network>
  <name>host-bridge</name>
  <forward mode='bridge'/>
  <bridge name='br0'/>
</network>
```

Apply to libvirt:
```bash
sudo virsh net-define bridge.xml
sudo virsh net-autostart host-bridge
sudo virsh net-start host-bridge
```

### 3. Use with vm_manager.sh

```bash
sudo ./vm_manager.sh create my-vm ~/.ssh br0
```


## Next Steps

This project is now a functional GitOps-managed IoT data pipeline. The following roadmap outlines the evolution towards a production-ready system:

### Phase 1: Data Persistence
- [ ] Add PostgreSQL Helm chart to `main-cluster` via ArgoCD.
- [ ] Update `golang-api` to persist incoming MQTT data into the database.

### Phase 2: Sensor Abstraction
- [ ] Refactor `rust-collector` to support a trait-based architecture.
- [ ] Add support for `SENSOR_TYPE=mock` and `SENSOR_TYPE=real` environment variables.

### Phase 3: Production Hardening
- [ ] Implement **ExternalDNS** to automatically sync LoadBalancer IPs with the public DDNS provider.
- [ ] Deploy **cert-manager** and configure **Let's Encrypt** for trusted SSL certificates.
- [ ] Replace self-signed configurations with real, CA-signed certificates for Rancher and service endpoints.

## cloud init


Tools needed to automate libvirt images

```
sudo zypper addrepo https://download.opensuse.org/repositories/Cloud:Tools/openSUSE_Tumbleweed/Cloud:Tools.repo
sudo zypper refresh
ssudo zypper install cloud-utils-isosudo zypper install cloud-utils-isoudo zypper install growpart cloud-init

```


## Allow vm to reach internet

#### Manual change -tested-

```
sudo iptables -t nat -I POSTROUTING 1 -s 192.168.122.0/24 ! -d 192.168.122.0/24 -j MASQUERADE
sudo iptables -I FORWARD 1 -i virbr0 -j ACCEPT
sudo iptables -I FORWARD 1 -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT   # <<<---- THIS IS IN FACT THE RULE THAT DO THE MAGIC !!!
# Delete manual changes
# 1. Remove the NAT/Masquerade rule
sudo iptables -t nat -D POSTROUTING -s 192.168.122.0/24 ! -d 192.168.122.0/24 -j MASQUERADE

# 2. Remove the Outbound Forward rule
sudo iptables -D FORWARD -i virbr0 -j ACCEPT

# 3. Remove the Inbound (Return) Forward rule
sudo iptables -D FORWARD -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
```


#### Permanent in firewalld

* Issue. As docker add his rules before the firewalld ones the `normal` changes don't work and `direct` rules needs to be added with `firewalld` as the ones with `iptables` in [previous](### Manual change -tested-)

* This don't work

```
sudo systemctl start firewalld
sudo firewall-cmd --permanent --zone=public --add-masquerade
sudo firewall-cmd --permanent --zone=libvirt --add-interface=virbr0
sudo firewall-cmd --permanent --zone=libvirt --set-target=ACCEPT
sudo firewall-cmd --reload
```

* This WORKS

```
# Allow Outbound from VM
sudo firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 0 -i virbr0 -j ACCEPT

# Allow Inbound Replies to VM
sudo firewall-cmd --permanent --direct --add-rule ipv4 filter FORWARD 0 -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Apply the changes
sudo firewall-cmd --reload
```
