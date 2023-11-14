# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "generic/ubuntu2204"
  config.ssh.insert_key = false

  '''
  config.vm.defne "vagrantvm" do |app|
    app.vm.hostname = "ookami-app.test"
    app.vm.network :private_network, ip:"192.168.57.55"
  end
  '''

  config.vm.network :private_network, ip:"192.168.57.55"

  config.vm.provision "ansible" do |ansible|
    ansible.playbook = "playbook.yml"
  end
end
