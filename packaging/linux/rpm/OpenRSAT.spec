%define buildroot ./builddir

Name:           OpenRSAT
Version:        %{_version}
Release:        1%{?dist}
Summary:        OpenRSAT made by Tranquil IT

BuildArch:	x86_64

License:        GPL
URL:            https://www.tranquil.it
Source0:        OpenRSAT
Source1:        OpenRSAT.png
Source2:        OpenRSAT.desktop
Source3:        OpenRSAT.en.po
Source4:        OpenRSAT.fr.po
Source5:        OpenRSAT.pl.po
Source6:        OpenRSAT.el.po
Source7:        OpenRSAT.zh.po

Requires:	bash, gtk2

%description

%install
rm -rf %{buildroot}

set -ex
mkdir -p %{buildroot}/opt/openrsat
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/openrsat/locale
mkdir -p %{buildroot}/usr/bin

install -Dpm0755 %{SOURCE0} %{buildroot}/opt/openrsat/OpenRSAT
install -Dpm0755 %{SOURCE1} %{buildroot}/opt/openrsat/OpenRSAT.png
install -Dpm0755 %{SOURCE2} %{buildroot}/usr/share/applications/OpenRSAT.desktop
install -Dpm0644 %{SOURCE3} %{buildroot}/usr/share/openrsat/locale/OpenRSAT.en.po
install -Dpm0644 %{SOURCE4} %{buildroot}/usr/share/openrsat/locale/OpenRSAT.fr.po
install -Dpm0644 %{SOURCE5} %{buildroot}/usr/share/openrsat/locale/OpenRSAT.pl.po
install -Dpm0644 %{SOURCE6} %{buildroot}/usr/share/openrsat/locale/OpenRSAT.el.po
install -Dpm0644 %{SOURCE7} %{buildroot}/usr/share/openrsat/locale/OpenRSAT.zh.po

%files
/opt/openrsat/OpenRSAT
/opt/openrsat/OpenRSAT.png
/usr/share/applications/OpenRSAT.desktop
/usr/share/openrsat/locale/OpenRSAT.en.po
/usr/share/openrsat/locale/OpenRSAT.fr.po
/usr/share/openrsat/locale/OpenRSAT.pl.po
/usr/share/openrsat/locale/OpenRSAT.el.po
/usr/share/openrsat/locale/OpenRSAT.zh.po

%post
rm -rf /usr/bin/OpenRSAT
ln -s /opt/openrsat/OpenRSAT /usr/bin/OpenRSAT