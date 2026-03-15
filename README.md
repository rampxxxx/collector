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



## Tooling


- Languages 
    - Golang , main for mostly everything.
    - Rust, target the edge for fast/ small footprint.
- k8s
    - k3s for edge.
    - Suse Rancher instead of Openshift for central k8s

- Deployment
    - gitops
    - helm
    - argocd
        - One central site in central k8s also controls edge k8s deployments.
