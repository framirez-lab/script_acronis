#!/bin/bash
# Script for checking Site-to-Site VPN from VPN appliance 

# Installing the required tools
install_tools() {
  echo "Checking if required tools are installed..."
  rpm -q epel-release > /dev/null 2>&1 || sudo yum --disablerepo=adrc-vpn-server -y install epel-release > /dev/null 2>&1

  local tools=("$@")  

  for tool in "${tools[@]}"; do
    if ! sudo rpm -q "$tool" > /dev/null 2>&1; then
      echo -e "Installing: $tool"
      if ! timeout 120s sudo yum --disablerepo=adrc-vpn-server -y install "$tool" > /dev/null 2>&1; then
        echo "[Error] Failed to install $tool within 120 seconds, check connectivity to Internet."
      else
        echo -e "Installed: $tool"
      fi
    fi
  done
  echo "Done."
}

# Check connectivity 
check_dc_connectivity() {
  echo -e "\tDC connectivity check\n"
  server_config="/etc/vpn-server/config.ini"

  # Check if the OpenVPN config file exists
  if [ ! -f "$server_config" ]; then
    echo -e "[Error] VPN server configuration file not found."
    return 1
  fi
  
  if grep -q '^dcURL' "$server_config"; then
    dc_address=$(awk -F '//' '/^dcURL/{print $NF}' $server_config)
  else
    echo -e "[Error] VPN appliance is not registered yet."
    return 1
  fi

  ip_addresses=($(dig +short "$dc_address"))
  exit_code=$?

  if [ $exit_code -ne 0 ] || [ ${#ip_addresses[@]} -eq 0 ]; then
    echo "[Error] Failed to resolve IP addresses for $dc_address"
    return 1
  fi

  ip_addresses_sorted=($(for ip in "${ip_addresses[@]}"; do echo $ip; done | sort))
  
  port=443
  echo -e "Checking connectivity with DC:\t$dc_address"
  for ip in "${ip_addresses_sorted[@]}"; do
    if nc -z -w 30 "$ip" "$port"; then
      echo "[Success] $ip:$port is reachable"
    else
      echo "[Error] $ip:$port is not reachable"
    fi
  done
}

# Check S2S OpenVPN tunnel 
check_tunnel() {
  echo -e "\tVPN tunnel status check\n"

  remote_peer=$(sudo ss -plant | awk '/ESTAB.*openvpn/ {print $5}')

  if [ -n "$remote_peer" ]; then
      echo "[Success] Found established connection with remote peer: $remote_peer"
  else
      echo "[Error] No established connections found."
  fi

}

# Check SOCKS proxy connectivity 
check_socks_connectivity() {
  echo -e "\tSOCKS Proxy connectivity check\n"
  openvpn_config="/etc/openvpn/client.conf"

  if [ ! -f "$openvpn_config" ]; then
    echo -e "[Error] OpenVPN configuration file not found."
    return 1
  fi

  if grep -q '^socks-proxy' "$openvpn_config"; then
    proxy_host=$(awk '/^socks-proxy/ {print $2}' $openvpn_config)
    proxy_port=$(awk '/^socks-proxy/ {print $3}' $openvpn_config)
  else
    echo -e "[Error] SOCKS proxy configuration not found in the OpenVPN config file."
    return 1
  fi
  
  echo -e "Checking connectivity to SOCKS proxy: $proxy_host:$proxy_port" 

  nc_cmd="sudo nc -z -v -w 30 $proxy_host $proxy_port"
  result=$($nc_cmd 2>&1)
  exit_code=$?

  if [ $exit_code -eq 0 ]; then
    echo -e "[Success] SOCKS proxy is reachable."
  else
    echo -e "[Error] SOCKS proxy is not reachable."
    echo "$result"
  fi 
}

# Check ARP duplicates
check_arp() {
  echo -e "\tARP duplicates check"
  
  fakemac=00:50:56:22:33:44
  
  # Get a list of all bridge interfaces
  bridge_interfaces=$(ip link show type bridge | awk -F ": " '/^[0-9]+:/ {print $2}')

  for bridgename in $bridge_interfaces; do
    echo -e "\nBRIDGE NAME:""\t"$bridgename

    bridgeip=$(ifconfig $bridgename | grep 'inet ' | awk '{print $2}')
    bridgemask=$(ifconfig $bridgename | grep 'inet ' | awk '{print $4}')

    if [ -z "$bridgeip" ] || [ -z "$bridgemask" ]; then
      echo "[Warning] IP address / mask not found for $bridgename, skipping."
      continue
    fi

    queryip=$(sudo sipcalc -i -4 -u  $bridgeip $bridgemask | grep 'Usable range' | awk '{print $6}')

    echo -e "BRIDGE IP:""\t"$bridgeip
    echo -e "BRIDGE MASK:""\t"$bridgemask
    echo -e "QUERY IP:""\t"$queryip

    nping_cmd="sudo nping --arp \
            --privileged \
            --source-mac $fakemac \
            --arp-type ARP \
            -e $bridgename \
            -v0 \
            -c 1 \
            --arp-target-ip $queryip \
            --arp-target-mac 00:00:00:00:00:00 \
            localhost \
            --hide-sent \
            --bpf-filter 'arp and ether host $fakemac' 2>/dev/null"

    rcvd=$(eval "$nping_cmd" | grep RCVD)
    echo -e "\n"$rcvd

    n_rcvd=$(echo "$rcvd" | wc -l)

    echo -e "ARP replies received for $bridgename:""\t$n_rcvd"
    
    if [ $n_rcvd -eq 0 ]; then
      echo -e "\n[Error] Something went wrong for $bridgename. Please contact the support team."
    elif [ $n_rcvd -eq 1 ]; then
      echo -e "\n[Success] No 'ARP' duplicates have been detected for $bridgename."
    elif [ $n_rcvd -gt 1 ]; then
      echo -e "\n[Error] Duplicated ARP packets have been detected in your network for $bridgename!"
      echo -e "Please follow the knowledge base article: https://kb.acronis.com/content/67434"
    fi
  done
}

delimiter="=========================================================="

install_tools sipcalc nmap bind-utils
echo "$delimiter"
check_arp
echo "$delimiter"
check_socks_connectivity
echo "$delimiter"
check_tunnel
echo "$delimiter"
check_dc_connectivity
echo "$delimiter"