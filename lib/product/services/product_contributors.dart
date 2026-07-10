class ProductContributor {
  const ProductContributor({
    required this.avatar,
    required this.name,
    required this.link,
  });

  final String avatar;
  final String name;
  final String link;
}

const productContributors = [
  ProductContributor(
    avatar: 'assets/images/avatars/makriq.png',
    name: 'makriq',
    link: 'https://github.com/makriq',
  ),
];
