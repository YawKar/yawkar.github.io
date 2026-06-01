+++
title = "Home"
template = "index.html"
in_search_index = true
[extra]
images = []
+++

# Home

Hey! You're welcome to know me better through my posts here =]

## whoami

- Karpov Vadim (<span id="my-age"></span> y.o.)
- I speak: \[English, Russian\]
- Topics I explore:
  - 🐧 Linux 
  - 💻 SW Engineering 
  - ⚙️ Systems programming 
  - ❄️ Nix/NixOS 

## Ways to reach me out

- [mail:yawkarpov@gmail.com](mailto:yawkarpov@gmail.com)
- [github:yawkar](https://github.com/yawkar)
- [telegram:@yawkar](https://yawkar.t.me)

<script>
    const birthDate = new Date("2003-02-27");
    const today = new Date();
    
    let age = today.getFullYear() - birthDate.getFullYear();
    const m = today.getMonth() - birthDate.getMonth();
    
    if (m < 0 || (m === 0 && today.getDate() < birthDate.getDate())) {
        age--;
    }
    
    document.getElementById("my-age").textContent = age;
</script>

