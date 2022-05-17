Vagrant.configure("2") do |config|
    ip = "192.168.56.15"
    config.vm.box = "ubuntu/focal64"
    config.vm.define "standalone-cluster" do | w |
        w.vm.hostname = "standalone-cluster"
        w.vm.network "private_network", ip: ip
  
        w.vm.provider "virtualbox" do |vb|
          vb.memory = "4096"
          vb.cpus = 2
          vb.gui = false
        end

        w.vm.provision "setup-packages", type: "shell", path: "setup-cluster.sh", env: { "CONTROL_PLANE_HOST" => ip }
    end
end
