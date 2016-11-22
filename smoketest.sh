
function create_xenial() {

  echo -n "Checking for Ubuntu Xenial: "
  glance image-list | grep -q ubuntu-xenial
  if [ $? != 0 ]; then
    echo "Installing"
    IMG='https://cloud-images.ubuntu.com/xenial/current/xenial-server-cloudimg-amd64-disk1.img'
    #wget $IMG
    FILE='cirros-0.3.0-x86_64-disk.img'
    glance image-create --file $FILE --name \
      'cirros' --disk-format qcow2 --container-format bare --progress
  else
    echo "Ok"
  fi
}

function create_networks() {

  echo -n "Checking for tenant networks: "
  neutron net-list | grep -q pcf-external
  if [ $? != 0 ]; then
    echo "Installing."
    neutron net-create pcf-external 
    neutron subnet-create pcf-external 172.16.0.0/23 --name pcf-external-subnet \
      --dns-nameservers list=true 10.65.248.10 10.65.248.11
  else
    echo "Ok"
  fi
}

function create_secgroup() {

   echo -n "Checking for admin security group: "
   neutron security-group-list |grep -q pcf-admin
   if [ $? != 0 ]; then
     echo "Creating."
     # Create the admin group
     neutron security-group-create pcf-admin &> /dev/null
     # Allow ssh
     neutron security-group-rule-create --direction ingress --ethertype IPv4 \
         --protocol tcp --port-range-min 22 --port-range-max 22 pcf-admin &> /dev/null
     # Allow http
     neutron security-group-rule-create --direction ingress --ethertype IPv4 \
         --protocol tcp --port-range-min 80 --port-range-max 80 pcf-admin &> /dev/null
     # Allow 443
     neutron security-group-rule-create --direction ingress --ethertype IPv4 \
         --protocol tcp --port-range-min 443 --port-range-max 443 pcf-admin &> /dev/null
     # Allow ICMP
     neutron security-group-rule-create --direction ingress --ethertype IPv4 \
         --protocol icmp pcf-admin &> /dev/null
   else
     echo "Ok"
   fi
}


function create_router() {

  echo -n "Checking for network router: "
  neutron router-list | grep rpub
  if [ $? != 0 ]; then
    echo "Creating."
    neutron router-create rpub
    neutron router-gateway-set rpub net04_ext
    neutron router-interface-add rpub pcf-external-subnet
  else
    echo "Ok"
  fi
}

function create_ssh_key() {

   echo -n "Checking crypto keys: "
   if [ ! -f ~/.ssh/pcf_id_rsa.pub ]; then
      rm -f ~/.ssh/pcf_id_id_rsa*
      echo "Installing"
      ssh-keygen -N '' -f ~/.ssh/pcf_id_rsa 
      chmod 600 ~/.ssh/pcf_id_rsa
      nova keypair-add --pub-key ~/.ssh/pcf_id_rsa.pub pcf-key 
   else
      echo "Ok"
   fi
}

function boot_instance() {

  echo -n "Checking for smoketest instance: "
  nova list | grep -q smoketest-rpub
  if [ $? != 0 ]; then
    echo "Creating."
    nova boot smoketest-rpub \
      --image $(glance image-list|grep ubuntu-xenial |awk '{print $2}') \
      --flavor $(nova flavor-list | grep m1.medium |  awk '{print $2}') \
      --nic net-id=$(neutron net-list | grep pcf-external | awk '{print $2}') \
      --key-name pcf-key \
      --security-groups pcf-admin
  else
    echo "Ok"
  fi
}

create_xenial
create_networks
create_router
create_ssh_key
create_secgroup
boot_instance


